import Foundation

/// 大端序读写工具 (Android: com.fgsqw.httpserver.utils.ByteUtil)
enum LByte {
    static func intToBytes(_ value: Int32, _ out: UnsafeMutablePointer<UInt8>, _ off: Int) {
        out[off] = UInt8(truncatingIfNeeded: value >> 24)
        out[off + 1] = UInt8(truncatingIfNeeded: value >> 16)
        out[off + 2] = UInt8(truncatingIfNeeded: value >> 8)
        out[off + 3] = UInt8(truncatingIfNeeded: value)
    }

    static func bytesToInt(_ b: [UInt8], _ off: Int) -> Int32 {
        guard off + 4 <= b.count else { return 0 }
        return Int32(bitPattern:
            (UInt32(b[off]) << 24) | (UInt32(b[off + 1]) << 16) | (UInt32(b[off + 2]) << 8) | UInt32(b[off + 3]))
    }

    static func longToBytes(_ value: Int64, _ out: UnsafeMutablePointer<UInt8>, _ off: Int) {
        for i in 0..<8 {
            out[off + i] = UInt8(truncatingIfNeeded: value >> (56 - 8 * i))
        }
    }

    static func bytesToLong(_ b: [UInt8], _ off: Int) -> Int64 {
        guard off + 8 <= b.count else { return 0 }
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(b[off + i]) }
        return Int64(bitPattern: v)
    }

    static func bytes(from string: String) -> [UInt8] {
        Array(string.utf8)
    }

    static func string(_ b: [UInt8], _ off: Int, _ len: Int) -> String {
        guard off >= 0, off + len <= b.count else { return "" }
        return String(decoding: b[off..<(off + len)], as: UTF8.self)
    }
}

/// UDP 数据包封装：12 字节头 + 包体，整包做 (b-1)^0x45 混淆
/// (Android: utils/DataEnc.java)
final class DataEnc {
    static let headerLen = 12

    private var bytes: [UInt8]
    private var byteLen: Int
    private var index = DataEnc.headerLen
    private var canEncData = false

    init(size: Int) {
        byteLen = size + DataEnc.headerLen
        bytes = [UInt8](repeating: 0, count: byteLen)
    }

    init(buffer: [UInt8]) {
        bytes = buffer
        byteLen = buffer.count
    }

    var dataLen: Int { index }
    var dataIndex: Int { index - DataEnc.headerLen }

    func setCmd(_ cmd: Int32) -> DataEnc {
        bytes.withUnsafeMutableBufferPointer { LByte.intToBytes(cmd, $0.baseAddress!, 0) }
        return self
    }

    func setByteCmd(_ cmd: UInt8) -> DataEnc {
        bytes[0] = cmd
        return self
    }

    func setCount(_ count: Int32) -> DataEnc {
        bytes.withUnsafeMutableBufferPointer { LByte.intToBytes(count, $0.baseAddress!, 4) }
        return self
    }

    func setLength(_ length: Int32) -> DataEnc {
        bytes.withUnsafeMutableBufferPointer { LByte.intToBytes(length, $0.baseAddress!, 8) }
        return self
    }

    @discardableResult
    func putByte(_ b: UInt8) -> DataEnc {
        ensureCapacity(1)
        bytes[index] = b
        index += 1
        return self
    }

    @discardableResult
    func putInt(_ v: Int32) -> DataEnc {
        ensureCapacity(4)
        bytes.withUnsafeMutableBufferPointer { LByte.intToBytes(v, $0.baseAddress!, index) }
        index += 4
        return self
    }

    @discardableResult
    func putLong(_ v: Int64) -> DataEnc {
        ensureCapacity(8)
        bytes.withUnsafeMutableBufferPointer { LByte.longToBytes(v, $0.baseAddress!, index) }
        index += 8
        return self
    }

    @discardableResult
    func putBool(_ v: Bool) -> DataEnc {
        putByte(v ? 1 : 0)
    }

    @discardableResult
    func putFloat(_ v: Float) -> DataEnc {
        putInt(Int32(v * 1000))
    }

    @discardableResult
    func putDouble(_ v: Double) -> DataEnc {
        putLong(Int64(v * 1_000_000))
    }

    @discardableResult
    func putBytes(_ bs: [UInt8]) -> DataEnc {
        ensureCapacity(4 + bs.count)
        putInt(Int32(bs.count))
        bytes.replaceSubrange(index..<(index + bs.count), with: bs)
        index += bs.count
        return self
    }

    @discardableResult
    func putString(_ v: String) -> DataEnc {
        putBytes(LByte.bytes(from: v))
    }

    func seek(_ offset: Int) {
        index = DataEnc.headerLen + offset
    }

    func skip(_ n: Int) {
        index += n
    }

    /// 写入包体长度并整包混淆
    func encData() -> [UInt8] {
        if canEncData {
            return Array(bytes[0..<index])
        }
        _ = setLength(Int32(index - DataEnc.headerLen))
        for i in 0..<index {
            bytes[i] = (bytes[i] &- 1) ^ 0x45
        }
        canEncData = true
        return Array(bytes[0..<index])
    }

    /// 未混淆的原始数据 (TCP DataEnc 通道使用)
    func getData() -> [UInt8] {
        _ = setLength(Int32(index - DataEnc.headerLen))
        return Array(bytes[0..<index])
    }

    private func ensureCapacity(_ extra: Int) {
        let need = index + extra
        if need > bytes.count {
            bytes.append(contentsOf: [UInt8](repeating: 0, count: need - bytes.count))
            byteLen = bytes.count
        }
    }
}

/// UDP/TCP 数据包解析 (Android: utils/DataDec.java)
final class DataDec {
    static let headerLen = 12

    private var bytes: [UInt8]
    private let byteLen: Int
    private var index = DataDec.headerLen

    init(_ bs: [UInt8]) {
        bytes = bs
        byteLen = bs.count
    }

    var cmd: Int32 { LByte.bytesToInt(bytes, 0) }
    var byteCmd: UInt8 { bytes.isEmpty ? 0 : bytes[0] }
    var count: Int32 { LByte.bytesToInt(bytes, 4) }
    var length: Int32 { LByte.bytesToInt(bytes, 8) }
    var dataIndex: Int { index - DataDec.headerLen }

    func getByte() -> UInt8 {
        if index + 1 <= byteLen {
            let b = bytes[index]
            index += 1
            return b
        }
        return 0
    }

    func getInt() -> Int32 {
        if index + 4 <= byteLen {
            let v = LByte.bytesToInt(bytes, index)
            index += 4
            return v
        }
        return 0
    }

    func getBool() -> Bool {
        getByte() == 1
    }

    func getLong() -> Int64 {
        if index + 8 <= byteLen {
            let v = LByte.bytesToLong(bytes, index)
            index += 8
            return v
        }
        return 0
    }

    func getFloat() -> Float {
        Float(getInt()) / 1000.0
    }

    func getDouble() -> Double {
        Double(getLong()) / 1_000_000.0
    }

    func getBytes() -> [UInt8] {
        let len = Int(getInt())
        guard len > 0, index + len <= byteLen else {
            if len == 0 { return [] }
            let tail = Array(bytes[min(index, byteLen)...])
            index = byteLen
            return tail
        }
        let temp = Array(bytes[index..<(index + len)])
        index += len
        return temp
    }

    func getString() -> String {
        String(decoding: getBytes(), as: UTF8.self)
    }

    var surplusBytes: [UInt8] {
        guard index < byteLen else { return [] }
        let temp = Array(bytes[index..<byteLen])
        index = byteLen
        return temp
    }

    func seek(_ offset: Int) {
        index = DataDec.headerLen + offset
    }

    func skip(_ n: Int) {
        index += n
    }

    func decHeader() {
        for i in 0..<min(DataDec.headerLen, byteLen) {
            bytes[i] = (bytes[i] ^ 0x45) &+ 1
        }
    }

    func decData() {
        let len = Int(max(0, length))
        let upper = min(DataDec.headerLen + len, byteLen)
        for i in DataDec.headerLen..<upper {
            bytes[i] = (bytes[i] ^ 0x45) &+ 1
        }
    }

    func decAllData() {
        decHeader()
        decData()
    }

    var data: [UInt8] { bytes }
}
