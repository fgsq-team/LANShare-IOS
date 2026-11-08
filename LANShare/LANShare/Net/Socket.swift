import Foundation
import Darwin

enum LSError: Error, CustomStringConvertible {
    case socketCreate(String)
    case bind(String)
    case listen(String)
    case connect(String)
    case timeout
    case closed
    case io(String)

    var description: String {
        switch self {
        case .socketCreate(let m): return "socket create failed: \(m)"
        case .bind(let m): return "bind failed: \(m)"
        case .listen(let m): return "listen failed: \(m)"
        case .connect(let m): return "connect failed: \(m)"
        case .timeout: return "timeout"
        case .closed: return "socket closed"
        case .io(let m): return "io error: \(m)"
        }
    }
}

private func lastError() -> String { String(cString: strerror(errno)) }

/// 本机 (Android: pojo/Device.java 的 devIP/devBrotIP 来源)
private func sockaddrIP(_ sa: sockaddr_storage) -> String {
    var storage = sa
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    switch Int32(storage.ss_family) {
    case AF_INET:
        withUnsafeBytes(of: &storage) { raw in
            let addr = raw.load(as: sockaddr_in.self).sin_addr
            inet_ntop(AF_INET, withUnsafePointer(to: addr) { UnsafeRawPointer($0) }, &buffer, socklen_t(buffer.count))
        }
    case AF_INET6:
        withUnsafeBytes(of: &storage) { raw in
            let addr = raw.load(as: sockaddr_in6.self).sin6_addr
            inet_ntop(AF_INET6, withUnsafePointer(to: addr) { UnsafeRawPointer($0) }, &buffer, socklen_t(buffer.count))
        }
    default:
        return ""
    }
    return String(cString: buffer)
}

/// `sockaddr` 只有 16 字节，按 sockaddr_in6(28 字节)直接 load 会越界触发运行时崩溃；
/// 一律先扩容成 sockaddr_storage 再解析。
private func sockaddrIP(_ sa: sockaddr) -> String {
    var storage = sockaddr_storage()
    withUnsafeBytes(of: sa) { src in
        withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: src) }
    }
    return sockaddrIP(storage)
}

/// 端口在 sockaddr_in / sockaddr_in6 里同偏移(第 2..4 字节)，但必须按各自结构读取长度
private func sockaddrPort(_ sa: sockaddr_storage) -> Int {
    var storage = sa
    return withUnsafeBytes(of: &storage) { raw in
        Int(UInt16(bigEndian: raw.load(fromByteOffset: 2, as: UInt16.self)))
    }
}

private func makeSockaddr(_ ip: String, port: Int) -> sockaddr_in? {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port)).bigEndian
    guard ip.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) == 1 }) else { return nil }
    return addr
}

/// 目标地址：Android 侧用 `InetSocketAddress(devIP, devPort)`，IPv4/IPv6 都能连；
/// 只支持 IPv4 会让对端仅有 IPv6 地址时发送直接失败，所以这里按地址族解析。
private struct LHostAddr {
    var storage: sockaddr_storage
    let family: Int32
    let length: socklen_t

    /// 用指针调用 connect/bind 等 POSIX 接口
    func withPointer<R>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> R) rethrows -> R {
        var copy = storage
        return try withUnsafeBytes(of: &copy) { raw in
            try body(raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), length)
        }
    }

    static func parse(_ ip: String, port: Int) -> LHostAddr? {
        var storage = sockaddr_storage()
        if ip.contains(":") {
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(port)).bigEndian
            var host = Substring(ip)
            if let pct = ip.firstIndex(of: "%") {
                host = ip[..<pct]
                // 链路本地地址必须带网卡序号，否则 connect 一律 EINVAL
                addr.sin6_scope_id = if_nametoindex(String(ip[ip.index(after: pct)...]))
            }
            guard String(host).withCString({ inet_pton(AF_INET6, $0, &addr.sin6_addr) == 1 }) else { return nil }
            withUnsafeBytes(of: &addr) { src in
                withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: src) }
            }
            return LHostAddr(storage: storage, family: AF_INET6, length: socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        guard ip.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) == 1 }) else { return nil }
        withUnsafeBytes(of: &addr) { src in
            withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: src) }
        }
        return LHostAddr(storage: storage, family: AF_INET, length: socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}

/// 阻塞式 TCP 连接，语义对齐 Java Socket + CustomDataInput/OutputStream
final class LTcpStream {
    let fd: Int32
    let remoteIP: String
    let remotePort: Int
    private let closeGate = NSLock()
    private var _closed = false
    var closed: Bool {
        closeGate.lock()
        defer { closeGate.unlock() }
        return _closed
    }
    private let writeLock = NSLock()
    private let readLock = NSLock()

    private init(fd: Int32, remoteIP: String, remotePort: Int) {
        self.fd = fd
        self.remoteIP = remoteIP
        self.remotePort = remotePort
        var noDelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
        var keepAlive: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &keepAlive, socklen_t(MemoryLayout<Int32>.size))
        // Java 的 socket 只会把对端断开上报为 IOException，BSD 的 send 却会先派发 SIGPIPE 杀死进程；
        // 所有连接（含主动 connect 出去的发送端）都必须屏蔽 SIGPIPE，让写操作返回 EPIPE 错误。
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    /// 对应 LANService.makeSocket：TCP_NODELAY + SO_KEEPALIVE + 5s 连接超时。
    /// 不绑定本机地址——Android 侧就是 `new Socket()` 直接 connect，由内核按目标地址选路；
    /// 强行绑定到 matchLocalDevice 挑出来的网卡会在 VPN/个人热点场景把连接绑死在
    /// utun/pdp_ip0 上，发往局域网地址时立刻 ENETUNREACH，而且对端完全收不到。
    static func connect(host: String, port: Int, timeoutSeconds: Int = 5) throws -> LTcpStream {
        guard let target = LHostAddr.parse(host, port: port) else {
            throw LSError.connect("invalid host \(host)")
        }
        let fd = socket(target.family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LSError.socketCreate(lastError()) }
        var flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let connected = target.withPointer { Darwin.connect(fd, $0, $1) }
        if connected != 0 {
            if errno != EINPROGRESS {
                Darwin.close(fd)
                throw LSError.connect(lastError())
            }
            var writeSet = try Self.writeSet(for: fd)
            var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
            var sel = select(fd + 1, nil, &writeSet, nil, &tv)
            if sel < 0, errno == EINTR {
                // 被信号打断不算失败，重试一次
                var retry = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
                sel = select(fd + 1, nil, &writeSet, nil, &retry)
            }
            if sel <= 0 {
                Darwin.close(fd)
                throw sel == 0 ? LSError.timeout : LSError.connect(lastError())
            }
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
            if soError != 0 {
                Darwin.close(fd)
                throw LSError.connect(String(cString: strerror(Int32(soError))))
            }
        }
        flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        let peer = sockaddrIP(LTcpStream.sockaddrFrom(fd: fd, peer: true))
        return LTcpStream(fd: fd, remoteIP: peer.isEmpty ? host : peer, remotePort: port)
    }

    /// Darwin 的 fd_set 是 32 个 32 位字组成的位图：必须按 fd/32 选字、fd%32 选位。
    /// 只写 fds_bits.0 的话，fd ≥ 32 时 select 监听的是另一个 (fd%32) 号——真机上应用
    /// 常态就有几十个 fd，会让连接立刻以 EBADF/超时失败；模拟器里 fd 很小所以复现不出。
    private static func writeSet(for fd: Int32) throws -> fd_set {
        guard fd >= 0, fd < Int32(FD_SETSIZE) else { throw LSError.connect("fd \(fd) out of select range") }
        var set = fd_set()
        withUnsafeMutableBytes(of: &set.fds_bits) { raw in
            let words = raw.bindMemory(to: Int32.self)
            words[Int(fd) / 32] |= Int32(1 << (Int(fd) % 32))
        }
        return set
    }

    static func accepted(fd: Int32, peer: sockaddr_storage) -> LTcpStream {
        let stream = LTcpStream(fd: fd, remoteIP: sockaddrIP(peer), remotePort: sockaddrPort(peer))
        return stream
    }

    private static func sockaddrFrom(fd: Int32, peer: Bool) -> sockaddr_storage {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = storage.withMutablePointer { peer ? getpeername(fd, $0, &len) : getsockname(fd, $0, &len) }
        return storage
    }

    func setReadTimeout(seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func setKeepAliveWriteTimeout(seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: - 原始读写

    func readUpTo(_ maxLen: Int) throws -> [UInt8] {
        readLock.lock()
        defer { readLock.unlock() }
        guard !closed else { throw LSError.closed }
        let size = max(min(maxLen, 65_536), 1)
        var buffer = [UInt8](repeating: 0, count: size)
        while true {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, size, 0) }
            if n > 0 {
                return Array(buffer[0..<Int(n)])
            }
            if n == 0 { throw LSError.closed }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw LSError.timeout }
            throw LSError.io(lastError())
        }
    }

    /// 等价于 CustomDataInputStream.readFully
    func readFully(_ count: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count)
        while out.count < count {
            let chunk = try readUpTo(count - out.count)
            out.append(contentsOf: chunk)
        }
        return out
    }

    func readByte() throws -> UInt8 {
        let b = try readFully(1)
        return b[0]
    }

    func readInt() throws -> Int32 {
        let b = try readFully(4)
        return LByte.bytesToInt(b, 0)
    }

    func readLong() throws -> Int64 {
        LByte.bytesToLong(try readFully(8), 0)
    }

    func readBoolean() throws -> Bool {
        try readByte() != 0
    }

    /// 等价于 CustomDataInputStream.readString（-1 表示 null，0 表示空串）
    func readString() throws -> String? {
        let len = Int(try readInt())
        if len == -1 { return nil }
        if len == 0 { return "" }
        return String(decoding: try readFully(len), as: UTF8.self)
    }

    func write(_ data: [UInt8]) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { throw LSError.closed }
        var offset = 0
        try data.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < data.count {
                let sent = Darwin.send(fd, base + offset, data.count - offset, 0)
                if sent > 0 {
                    offset += sent
                    continue
                }
                if sent < 0, errno == EINTR { continue }
                throw LSError.io(lastError())
            }
        }
    }

    func writeByte(_ b: UInt8) throws {
        try write([b])
    }

    func writeInt(_ v: Int32) throws {
        var b = [UInt8](repeating: 0, count: 4)
        b.withUnsafeMutableBufferPointer { LByte.intToBytes(v, $0.baseAddress!, 0) }
        try write(b)
    }

    func writeLong(_ v: Int64) throws {
        var b = [UInt8](repeating: 0, count: 8)
        b.withUnsafeMutableBufferPointer { LByte.longToBytes(v, $0.baseAddress!, 0) }
        try write(b)
    }

    func writeBoolean(_ v: Bool) throws {
        try writeByte(v ? 1 : 0)
    }

    /// 等价于 CustomDataOutputStream.writeString（null 写 -1）
    func writeString(_ s: String?) throws {
        guard let s else {
            try writeInt(-1)
            return
        }
        let bytes = LByte.bytes(from: s)
        try writeInt(Int32(bytes.count))
        try write(bytes)
    }

    /// 对应 Java out.write(int)：只写 1 个字节
    func writeSingleByte(_ v: Int32) throws {
        try writeByte(UInt8(truncatingIfNeeded: v))
    }

    /// 对应 Java socket.shutdownOutput()：半关闭写通道，让对端读到 EOF
    func shutdownWrite() {
        if closed { return }
        _ = Darwin.shutdown(fd, SHUT_WR)
    }

    func close() {
        closeGate.lock()
        let already = _closed
        _closed = true
        closeGate.unlock()
        guard !already else { return }
        // 只 shutdown，不提前 close：正在 recv 的线程若被解阻塞后 fd 号已被新连接复用，
        // 就会读到别人的数据甚至崩溃。fd 由 deinit 在最后一个持有者释放时关闭。
        shutdown(fd, SHUT_RDWR)
    }

    deinit {
        Darwin.close(fd)
    }
}

private extension sockaddr {
    mutating func withMutablePointer<R>(_ body: (UnsafeMutablePointer<sockaddr>) -> R) -> R {
        withUnsafeMutablePointer(to: &self) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0) }
        }
    }
}

private extension sockaddr_storage {
    mutating func withMutablePointer<R>(_ body: (UnsafeMutablePointer<sockaddr>) -> R) -> R {
        withUnsafeMutablePointer(to: &self) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0) }
        }
    }
}

/// TCP 监听 (Android: TcpServerManager 的 ServerSocket)
final class LTcpListener {
    let fd: Int32
    let port: Int
    private let closeGate = NSLock()
    private var _closed = false
    private var isClosed: Bool {
        closeGate.lock()
        defer { closeGate.unlock() }
        return _closed
    }

    init(port: Int) throws {
        self.port = port
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LSError.socketCreate(lastError()) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr = in_addr(s_addr: 0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw LSError.bind(lastError())
        }
        guard listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw LSError.listen(lastError())
        }
        self.fd = fd
    }

    /// 阻塞 accept；close() 后抛错退出循环
    func accept() throws -> LTcpStream {
        var peer = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let client = peer.withMutablePointer { acceptFd(fd, $0, &len) }
        guard client >= 0 else {
            if errno == EINTR { return try accept() }
            throw LSError.io(lastError())
        }
        // close() 之后返回的连接 fd 号可能已被别的 socket 复用，不接管，直接归还
        if isClosed {
            Darwin.close(client)
            throw LSError.closed
        }
        return LTcpStream.accepted(fd: client, peer: peer)
    }

    private func acceptFd(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>, _ len: UnsafeMutablePointer<socklen_t>) -> Int32 {
        Darwin.accept(fd, addr, len)
    }

    func close() {
        closeGate.lock(); let already = _closed; _closed = true; closeGate.unlock()
        guard !already else { return }
        // 先 shutdown 唤醒阻塞中的 accept，再 close：否则 close 后 accept 仍可能返回，
        // 而 fd 号已被其它线程新建的 socket 复用。
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

/// UDP 通道 (Android: DatagramSocket / MulticastSocket)
final class LUdpChannel {
    let fd: Int32

    /// 接收通道：绑定端口，开启广播
    init(bindPort: Int, bindIP: String? = nil) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw LSError.socketCreate(lastError()) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var broadcast: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(bindPort)).bigEndian
        addr.sin_addr = bindIP.flatMap { NetUtils.ipv4ToInt($0) }.map { in_addr(s_addr: UInt32($0).littleEndian) }
            ?? in_addr(s_addr: 0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw LSError.bind(lastError())
        }
        self.fd = fd
    }

    /// 发送通道：临时 socket，必要时绑定到指定网卡地址（iOS 广播需要）
    static func sending(localIP: String?) throws -> LUdpChannel {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw LSError.socketCreate(lastError()) }
        var broadcast: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))
        if let localIP, var value = NetUtils.ipv4ToInt(localIP) {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr = in_addr(s_addr: UInt32(value).littleEndian)
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if bound != 0 {
                LLog.debug("udp bind source \(localIP) failed: \(lastError())")
            }
            value = 0
        }
        return LUdpChannel(existingFd: fd)
    }

    private init(existingFd: Int32) {
        fd = existingFd
    }

    func send(_ data: [UInt8], to ip: String, port: Int) throws {
        guard var addr = makeSockaddr(ip, port: port) else { throw LSError.io("bad dest \(ip)") }
        try data.withUnsafeBytes { raw in
            let result = withUnsafePointer(to: &addr) { ptr -> Int in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(fd, raw.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result < 0 { throw LSError.io(lastError()) }
        }
    }

    func receive(maxSize: Int = 4096) throws -> (data: [UInt8], fromIP: String, fromPort: Int) {
        var buffer = [UInt8](repeating: 0, count: maxSize)
        var peer = sockaddr()
        var len = socklen_t(MemoryLayout<sockaddr>.size)
        let n = buffer.withUnsafeMutableBytes { raw in
            peer.withMutablePointer { recvfrom(fd, raw.baseAddress, maxSize, 0, $0, &len) }
        }
        guard n > 0 else {
            if errno == EINTR { return try receive(maxSize: maxSize) }
            throw LSError.io(lastError())
        }
        let port = Int(UInt16(bigEndian: withUnsafeBytes(of: peer) { $0.load(as: sockaddr_in.self).sin_port }))
        return (Array(buffer[0..<n]), sockaddrIP(peer), port)
    }

    func setReadTimeout(seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func close() {
        Darwin.close(fd)
    }
}
