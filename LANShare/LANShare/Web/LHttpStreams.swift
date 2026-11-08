import Foundation

/// Socket 的双向缓冲通道 (HttpServer: socket InputStream + OutputStream + utils/IOUtil.java)
/// 读侧带内部缓冲，语义等价于 Java 的 BufferInputStream。
final class LHttpSocket {
    let stream: LTcpStream
    private var buffer: [UInt8] = []
    private var index = 0
    private var eofHit = false
    private let gate = NSLock()

    init(_ stream: LTcpStream) {
        self.stream = stream
    }

    var remoteIP: String { stream.remoteIP }
    var remotePort: Int { stream.remotePort }
    var isClosed: Bool { stream.closed }

    func setReadTimeout(seconds: Int) { stream.setReadTimeout(seconds: seconds) }

    // MARK: - 读

    /// 等价于 InputStream.read()，-1 表示流结束
    func readByte() -> Int {
        gate.lock()
        defer { gate.unlock() }
        if index >= buffer.count, !refillLocked() { return -1 }
        let b = buffer[index]
        index += 1
        return Int(b)
    }

    /// Java InputStream.read() 的可选语义
    func readByteOptional() -> UInt8? {
        let v = readByte()
        return v == -1 ? nil : UInt8(truncatingIfNeeded: v)
    }

    /// 等价于 InputStream.read(b, off, len)：最多读 len 个字节，nil 表示结束
    func read(_ maxLen: Int) -> [UInt8]? {
        gate.lock()
        defer { gate.unlock() }
        if maxLen <= 0 { return [] }
        if index >= buffer.count, !refillLocked() { return nil }
        let n = min(maxLen, buffer.count - index)
        let out = Array(buffer[index..<(index + n)])
        index += n
        return out
    }

    /// 等价于 IOUtil.readFully：阻塞读满 len，提前结束返回 nil
    func readFully(_ len: Int) -> [UInt8]? {
        guard len >= 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(len)
        while out.count < len {
            guard let chunk = read(len - out.count), !chunk.isEmpty else { return nil }
            out.append(contentsOf: chunk)
        }
        return out
    }

    /// 等价于 InputStream.skip(n)
    @discardableResult
    func skip(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        var skipped = 0
        while skipped < count {
            gate.lock()
            if index >= buffer.count, !refillLocked() {
                gate.unlock()
                break
            }
            let n = min(count - skipped, buffer.count - index)
            index += n
            gate.unlock()
            skipped += n
        }
        return skipped
    }

    private func refillLocked() -> Bool {
        if eofHit { return false }
        buffer = (try? stream.readUpTo(16_384)) ?? []
        index = 0
        if buffer.isEmpty { eofHit = true }
        return !buffer.isEmpty
    }

    // MARK: - 写

    func write(_ bytes: [UInt8]) throws {
        guard !isClosed else { throw LSError.closed }
        try stream.write(bytes)
    }

    func write(_ text: String) throws {
        try write(Array(text.utf8))
    }

    /// 等价于 OutputStream.write(int)：只写 1 字节
    func writeByte(_ value: Int) throws {
        try stream.writeByte(UInt8(truncatingIfNeeded: value))
    }

    /// 半关闭：通知对端数据写完 (Java socket.shutdownOutput)
    func shutdownWrite() {
        stream.shutdownWrite()
    }

    func close() {
        gate.lock()
        eofHit = true
        buffer = []
        index = 0
        gate.unlock()
        stream.close()
    }
}

/// HttpServer: utils/HttpUtil.java 的请求行读取 + utils/IOUtil.java 的流搬运
enum LHttpIO {
    /// readHttpLine：不含行尾 CRLF
    static func readLine(_ sock: LHttpSocket) -> String? {
        var bytes = [UInt8]()
        while true {
            let read = sock.readByte()
            if read == -1 { return nil }
            let byte = UInt8(truncatingIfNeeded: read)
            if byte == UInt8(ascii: "\r") {
                if sock.readByte() == UInt8(ascii: "\n") { break }
            }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// readHttpLineByte：保留行尾 CRLF
    static func readLineBytes(_ sock: LHttpSocket) -> [UInt8]? {
        var bytes = [UInt8]()
        while true {
            guard let byte = sock.readByteOptional() else { return nil }
            bytes.append(byte)
            if byte == UInt8(ascii: "\r") {
                guard let next = sock.readByteOptional() else { return nil }
                bytes.append(next)
                if next == UInt8(ascii: "\n") { break }
            }
        }
        return bytes
    }

    /// IOUtil.transfer(input, output)
    @discardableResult
    static func transfer(_ input: LStreamSource, _ output: LHttpSocket) -> Int64 {
        var total: Int64 = 0
        while true {
            guard let chunk = input.read(81_920), !chunk.isEmpty else { break }
            try? output.write(chunk)
            total += Int64(chunk.count)
        }
        return total
    }

    /// IOUtil.transfer(input, output, size)
    @discardableResult
    static func transfer(_ input: LStreamSource, _ output: LHttpSocket, size: Int64) -> Int64 {
        var total: Int64 = 0
        while total < size {
            let want = Int(min(size - total, 4096))
            guard let chunk = input.read(want), !chunk.isEmpty else { break }
            try? output.write(chunk)
            total += Int64(chunk.count)
        }
        return total
    }

    /// IOUtil.readBytes：读满整个流
    static func readAll(_ input: LStreamSource) -> [UInt8] {
        var out = [UInt8]()
        while true {
            guard let chunk = input.read(81_920), !chunk.isEmpty else { break }
            out.append(contentsOf: chunk)
        }
        return out
    }
}

/// 可分段读取的字节来源 (对应 Java InputStream 抽象)
protocol LStreamSource: AnyObject {
    func read(_ maxLen: Int) -> [UInt8]?
}

extension LHttpSocket: LStreamSource {}

/// 请求体限制流 (HttpServer: stream/BodyInputStream.java)
final class LBodyInputStream: LStreamSource {
    private let input: LHttpSocket
    private var size: Int

    init(_ input: LHttpSocket, size: Int) {
        self.input = input
        self.size = size
    }

    func read(_ maxLen: Int) -> [UInt8]? {
        if size <= 0 { return nil }
        guard let chunk = input.read(min(maxLen, size)) else { return nil }
        size -= chunk.count
        return chunk
    }

    /// Request.getRequestBody()
    func readAllText() -> String {
        String(decoding: LHttpIO.readAll(self), as: UTF8.self)
    }
}

/// 单文件上传流 (HttpServer: stream/SingleUploadInputStream.java)
final class LSingleUploadInputStream: LStreamSource {
    private let input: LHttpSocket
    private(set) var fileName: String?
    private(set) var fileSize: Int64 = 0
    private var readSize: Int64 = 0

    init?(request: LHttpRequest) {
        input = request.socket
        var firstLineLength = -1
        var readHeadLength: Int64 = 0
        var filename: String?
        var ready = false
        while true {
            guard let lineBytes = LHttpIO.readLineBytes(input) else { break }
            if firstLineLength == -1 {
                // 减去尾部分割数据
                firstLineLength = lineBytes.count + 4
            }
            readHeadLength += Int64(lineBytes.count)
            let line = String(decoding: lineBytes, as: UTF8.self)
            let upper = line.uppercased()
            if upper.hasPrefix(LHttpConstant.contentDisposition.uppercased()) {
                filename = LSingleUploadInputStream.parseFilename(upper: upper, line: line)
            }
            if upper.hasPrefix(LHttpConstant.contentType.uppercased()) {
                if filename == nil { filename = LHttpSocketUtils.uuid() }
                self.fileName = filename
                // 精确跳过 \r\n
                _ = input.readByte()
                _ = input.readByte()
                readHeadLength += 2
                // 数据长度 = 总请求体长度 - (尾部分割行长度 + 已读请求体长度)
                fileSize = Int64(request.contentLength) - (Int64(firstLineLength) + readHeadLength)
                ready = true
                break
            }
        }
        if !ready { return nil }
    }

    static func parseFilename(upper: String, line: String) -> String? {
        guard let range = upper.range(of: "FILENAME=\"") else { return nil }
        let offset = upper.distance(from: upper.startIndex, to: range.upperBound)
        guard offset <= line.count else { return nil }
        let tail = String(line.dropFirst(offset))
        let name = String(tail.prefix(while: { $0 != "\"" }))
        return name.isEmpty ? nil : name
    }

    func read(_ maxLen: Int) -> [UInt8]? {
        if readSize >= fileSize { return nil }
        let want = Int(min(fileSize - readSize, Int64(max(maxLen, 1))))
        guard let chunk = input.read(want) else { return nil }
        readSize += Int64(chunk.count)
        return chunk
    }

    /// Request.transferUploadFile(path)
    func save(toDirectory dir: String) -> LUploadResult? {
        let name = fileName ?? LHttpSocketUtils.uuid()
        let path = LHttpSocketUtils.avoidDuplication((dir as NSString).appendingPathComponent(name))
        guard let handle = LHttpSocketUtils.createFile(path) else { return nil }
        defer { handle.closeFile() }
        while true {
            guard let chunk = read(81_920), !chunk.isEmpty else { break }
            chunk.withUnsafeBytes { handle.write(Data(bytes: $0.baseAddress!, count: chunk.count)) }
        }
        let result = LUploadResult()
        result.fileName = name
        result.filePath = path
        result.fileSize = fileSize
        return result
    }
}

/// 多文件上传流 (HttpServer: stream/MultUploadInputStream.java)
final class LMultUploadInputStream: LStreamSource {
    private let input: LHttpSocket
    private let boundaryByte: [UInt8]
    private let boundary: String
    private let request: LHttpRequest
    private(set) var fileName: String?
    private(set) var fileSize: Int64 = 0
    private var readSize: Int64 = 0
    private(set) var hasNext = false

    private var cache = [UInt8](repeating: 0, count: 256)
    private var readCount = 0
    private var readIndex = 0
    private var readCompleted = false

    /// 首个分片：读取 boundary，再解析首个分片的头部
    init?(request: LHttpRequest) {
        guard let header = request.getHeaderValue(LHttpConstant.contentType),
              let range = header.range(of: "boundary=", options: .backwards) else { return nil }
        var value = String(header[range.upperBound...])
        if let semi = value.firstIndex(of: ";") { value = String(value[..<semi]) }
        let bnd = "--" + value
        self.request = request
        input = request.socket
        boundary = bnd
        boundaryByte = Array(bnd.utf8)
        var found = false
        while let line = LHttpIO.readLine(input) {
            if line.isEmpty { continue }
            if line.hasPrefix(bnd) { found = true; break }
        }
        guard found, readPartHeader() else { return nil }
    }

    /// 后续分片
    private init(request: LHttpRequest, input: LHttpSocket, boundary: String, boundaryByte: [UInt8]) {
        self.request = request
        self.input = input
        self.boundary = boundary
        self.boundaryByte = boundaryByte
    }

    /// 下一个文件，nil 表示已结束
    func next() -> LMultUploadInputStream? {
        guard hasNext else { return nil }
        let stream = LMultUploadInputStream(request: request, input: input, boundary: boundary, boundaryByte: boundaryByte)
        return stream.readPartHeader() ? stream : nil
    }

    /// readFileContentType
    @discardableResult
    func readPartHeader() -> Bool {
        while true {
            guard let line = LHttpIO.readLine(input), !line.isEmpty else { return false }
            let upper = line.uppercased()
            if upper.hasPrefix(LHttpConstant.contentDisposition.uppercased()) {
                fileName = LSingleUploadInputStream.parseFilename(upper: upper, line: line)
            } else if upper.hasPrefix(LHttpConstant.contentType.uppercased()) {
                if fileName == nil { fileName = LHttpSocketUtils.uuid() }
                _ = input.skip(2)
                return true
            }
        }
    }

    /// read()：逐字节状态机，遇到 "\r\n" + boundary 即结束当前分片
    private func readOneByte() -> Int {
        if readCompleted { return -1 }
        if readCount > 0 {
            readCount -= 1
            readSize += 1
            fileSize += 1
            let v = Int(cache[readIndex])
            readIndex += 1
            return v
        }
        readIndex = 0
        guard let read = input.readByteOptional() else {
            readCompleted = true
            return -1
        }
        readSize += 1
        if read == UInt8(ascii: "\r") {
            guard let r = input.readByteOptional() else {
                readCompleted = true
                return Int(UInt8(ascii: "\r"))
            }
            readSize += 1
            if r != UInt8(ascii: "\n") {
                cache[0] = r
                readCount = 1
                readIndex = 0
                fileSize += 1
                return Int(UInt8(ascii: "\r"))
            }
            cache[0] = UInt8(ascii: "\r")
            cache[1] = UInt8(ascii: "\n")
            readCount = 2
            var flag = true
            for b in boundaryByte {
                guard let value = input.readByteOptional() else {
                    readCompleted = true
                    let v = Int(cache[readIndex])
                    readIndex += 1
                    return v
                }
                readSize += 1
                if readCount >= cache.count {
                    cache.append(contentsOf: [UInt8](repeating: 0, count: cache.count))
                }
                cache[readCount] = value
                readCount += 1
                if value != b {
                    flag = false
                    break
                }
            }
            if flag {
                let b1 = input.readByteOptional()
                let b2 = input.readByteOptional()
                if let a = b1, let c = b2 {
                    hasNext = !(a == UInt8(ascii: "-") && c == UInt8(ascii: "-"))
                }
                readCompleted = true
                return -1
            }
        }
        fileSize += 1
        return Int(read)
    }

    func read(_ maxLen: Int) -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(min(max(maxLen, 1), 8192))
        while out.count < maxLen {
            let v = readOneByte()
            if v == -1 { break }
            out.append(UInt8(truncatingIfNeeded: v))
        }
        return out.isEmpty ? nil : out
    }

    /// 落盘到目录，返回上传结果
    func save(toDirectory dir: String) -> LUploadResult? {
        let name = fileName ?? LHttpSocketUtils.uuid()
        let path = LHttpSocketUtils.avoidDuplication((dir as NSString).appendingPathComponent(name))
        guard let handle = LHttpSocketUtils.createFile(path) else { return nil }
        defer { handle.closeFile() }
        while true {
            guard let chunk = read(81_920), !chunk.isEmpty else { break }
            handle.write(Data(chunk))
        }
        let result = LUploadResult()
        result.fileName = name
        result.filePath = path
        result.fileSize = fileSize
        return result
    }
}

/// 上传结果 (Request.UploadResult)
final class LUploadResult {
    var fileName = ""
    var filePath = ""
    var fileSize: Int64 = 0
}

/// utils/FileUtil.java + utils/StringUtils.java 的常用部分
enum LHttpSocketUtils {
    static func uuid() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }

    static func isEmpty(_ text: String?) -> Bool { text == nil || text!.isEmpty }

    /// FileUtil.computeSize(long)
    static func computeSize(_ size: Int64) -> String {
        if size <= 0 { return "0B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        let groups = min(Int(log10(Double(size)) / log10(1024)), units.count - 1)
        let value = Double(size) / pow(1024, Double(groups))
        return String(format: "%.1f %@", value, units[groups])
    }

    /// FileUtil.avoidDuplication：重名文件追加 (n)
    static func avoidDuplication(_ path: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return path }
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        let hasDot = name.contains(".")
        let prefix = hasDot ? String(name.prefix(upTo: name.lastIndex(of: ".")!)) : name
        let suffix = hasDot ? String(name[name.lastIndex(of: ".")!...]) : ""
        for i in 1..<65535 {
            let candidate = (parent as NSString).appendingPathComponent(hasDot ? "\(prefix)(\(i))\(suffix)" : "\(name)(\(i))")
            if !fm.fileExists(atPath: candidate) { return candidate }
        }
        return path
    }

    static func createFile(_ path: String) -> FileHandle? {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        fm.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }
}
