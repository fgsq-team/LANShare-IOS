import Foundation
import CryptoKit

/// WebSocket 帧编解码 (HttpServer: websocket/WebSocketUtil.java)
enum LWebSocketUtil {
    static let wsFin = 128
    static let opcodeContinuation = 0
    static let opcodeText = 1
    static let opcodeBinary = 2
    static let opcodeClose = 8
    static let opcodePing = 9
    static let opcodePong = 10

    /// 单帧上限，防止畸形长度撑爆内存
    private static let maxFrameLength = 32 * 1024 * 1024

    struct FrameData {
        let data: [UInt8]?
        let opcode: Int
    }

    static func isControlFrame(_ frameType: Int) -> Bool {
        frameType == opcodeClose || frameType == opcodePing || frameType == opcodePong
    }

    /// 对应 getFrameLength
    static func getFrameLength(_ mask: Int, _ sock: LHttpSocket) -> Int64 {
        var frameLength = Int64(mask & 0x7F)
        if frameLength == 126 {
            guard let buf = sock.readFully(2), buf.count == 2 else { return -1 }
            frameLength = Int64((UInt16(buf[0]) << 8) | UInt16(buf[1]))
        } else if frameLength == 127 {
            guard let buf = sock.readFully(8), buf.count == 8 else { return -1 }
            var value: UInt64 = 0
            for b in buf { value = (value << 8) | UInt64(b) }
            frameLength = Int64(truncatingIfNeeded: value)
        }
        return frameLength
    }

    static func readFrame(_ sock: LHttpSocket, isClient: Bool) throws -> FrameData? {
        isClient ? try readClientFrame(sock) : try readServerFrame(sock)
    }

    /// 对应 readClientFrame（本端作为客户端读取服务端帧：无掩码）
    static func readClientFrame(_ sock: LHttpSocket) throws -> FrameData? {
        let curByte = sock.readByte()
        guard curByte != -1 else { throw LSError.closed }
        let opcode = curByte & 0xF
        if opcode == opcodeClose { return FrameData(data: nil, opcode: opcode) }
        if (curByte & 0x70) > 0 { return nil }
        let maskByte = sock.readByte()
        let frameLength = getFrameLength(maskByte, sock)
        if frameLength < 0 || frameLength > Int64(maxFrameLength) { return nil }
        if isControlFrame(opcode) && frameLength > 125 { return nil }
        if opcode == opcodeText || opcode == opcodeBinary {
            guard let data = sock.readFully(Int(frameLength)), data.count == Int(frameLength) else { return nil }
            return FrameData(data: data, opcode: opcode)
        } else if opcode == opcodePing || opcode == opcodePong {
            LLog.debug("ws ping/pong received")
        }
        return nil
    }

    /// 对应 readServerFrame（本端作为服务端读取浏览器帧：带掩码）
    static func readServerFrame(_ sock: LHttpSocket) throws -> FrameData? {
        let curByte = sock.readByte()
        guard curByte != -1 else { throw LSError.closed }
        let opcode = curByte & 0xF
        if opcode == opcodeClose { return FrameData(data: nil, opcode: opcode) }
        if (curByte & 0x70) > 0 { return nil }
        let maskByte = sock.readByte()
        guard maskByte != -1 else { throw LSError.closed }
        let hasMask = (maskByte & 0x80) != 0
        let frameLength = getFrameLength(maskByte & 0x7F, sock)
        if frameLength < 0 || frameLength > Int64(maxFrameLength) { return nil }
        if isControlFrame(opcode) && frameLength > 125 { return nil }
        if opcode == opcodeText || opcode == opcodeBinary || isControlFrame(opcode) {
            var masks = [UInt8](repeating: 0, count: 4)
            if hasMask {
                guard let read = sock.readFully(4), read.count == 4 else { return nil }
                masks = read
            }
            var data = sock.readFully(Int(frameLength)) ?? []
            guard data.count == Int(frameLength) else { return nil }
            if hasMask {
                for i in 0..<data.count {
                    data[i] ^= masks[i & 0x3]
                }
            }
            if opcode == opcodeText || opcode == opcodeBinary {
                return FrameData(data: data, opcode: opcode)
            }
            // 控制帧载荷已读走，避免后续帧错位
            LLog.debug("ws ping/pong received")
            return nil
        }
        return nil
    }

    /// 对应 sendServerFrame：服务端不掩码
    static func sendServerFrame(_ out: LHttpSocket, data: [UInt8], opCode: Int) throws {
        var head = [UInt8]()
        head.append(UInt8(wsFin | opCode))
        let len = data.count
        if len < 126 {
            head.append(UInt8(len))
        } else if len <= 65535 {
            head.append(126)
            head.append(UInt8((len >> 8) & 0xFF))
            head.append(UInt8(len & 0xFF))
        } else {
            head.append(127)
            var value = UInt64(len).bigEndian
            withUnsafeBytes(of: &value) { head.append(contentsOf: $0) }
        }
        try out.write(head)
        if !data.isEmpty { try out.write(data) }
    }

    /// 对应 sendClientFrame：客户端必须掩码
    static func sendClientFrame(_ out: LHttpSocket, data: [UInt8], opCode: Int) throws {
        let mask = generateMask()
        var head = [UInt8]()
        head.append(UInt8(wsFin | opCode))
        let len = data.count
        if len < 126 {
            head.append(UInt8(len) | 0x80)
            head.append(contentsOf: mask)
        } else if len <= 65535 {
            head.append(126 | 0x80)
            head.append(UInt8((len >> 8) & 0xFF))
            head.append(UInt8(len & 0xFF))
            head.append(contentsOf: mask)
        } else {
            head.append(127 | 0x80)
            var value = UInt64(len).bigEndian
            withUnsafeBytes(of: &value) { head.append(contentsOf: $0) }
            head.append(contentsOf: mask)
        }
        var masked = data
        for i in 0..<masked.count { masked[i] ^= mask[i % 4] }
        try out.write(head)
        try out.write(masked)
    }

    static func generateMask() -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: 4)
        for i in 0..<4 { mask[i] = UInt8.random(in: 0...255) }
        return mask
    }
}

/// WebSocket 服务端连接 (HttpServer: websocket/WebSocketServer.java)
final class LWebSocketServer {
    private let socket: LHttpSocket
    private let gate = NSLock()
    private var closedFlag = false

    var isClosed: Bool {
        gate.lock()
        defer { gate.unlock() }
        return closedFlag || socket.isClosed
    }

    var remoteIP: String { socket.remoteIP }

    init(secWebSocketKey: String?, socket: LHttpSocket) throws {
        self.socket = socket
        try writeWebSocket(secWebSocketKey)
    }

    /// 对应 writeWebSocket：SHA1(key + magic) 的 base64 作为 accept
    private func writeWebSocket(_ webSocketKey: String?) throws {
        guard let webSocketKey, !webSocketKey.isEmpty else { return }
        let digest = Insecure.SHA1.hash(data: Array((webSocketKey + LHttpConstant.wsMagic).utf8))
        let handshakeAccept = Data(digest).base64EncodedString()
        let text = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: " + handshakeAccept
            + "\r\n\r\n"
        try socket.write(text)
    }

    /// 对应 readFrame
    func readFrame() throws -> LWebSocketUtil.FrameData? {
        guard !isClosed else { throw LSError.closed }
        return try LWebSocketUtil.readFrame(socket, isClient: false)
    }

    /// 对应 readString：EOF 或空帧返回 nil
    func readString() throws -> String? {
        guard let frame = try readFrame() else { return nil }
        guard let data = frame.data else {
            if frame.opcode == LWebSocketUtil.opcodeClose { close() }
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    func readBinary() throws -> [UInt8]? {
        guard let frame = try readFrame() else { return nil }
        return frame.data
    }

    func sendString(_ msg: String) throws {
        try send { try LWebSocketUtil.sendServerFrame(socket, data: Array(msg.utf8),
                                                      opCode: LWebSocketUtil.opcodeText) }
    }

    func sendBinary(_ data: [UInt8]) throws {
        try send { try LWebSocketUtil.sendServerFrame(socket, data: data,
                                                      opCode: LWebSocketUtil.opcodeBinary) }
    }

    func sendClose() throws {
        try send { try LWebSocketUtil.sendServerFrame(socket, data: [],
                                                      opCode: LWebSocketUtil.opcodeClose) }
    }

    func sendPing() throws {
        try send { try LWebSocketUtil.sendServerFrame(socket, data: [],
                                                      opCode: LWebSocketUtil.opcodePing) }
    }

    private func send(_ body: () throws -> Void) throws {
        gate.lock()
        defer { gate.unlock() }
        guard !closedFlag else { throw LSError.closed }
        try body()
    }

    func close() {
        gate.lock()
        closedFlag = true
        gate.unlock()
        socket.close()
    }
}
