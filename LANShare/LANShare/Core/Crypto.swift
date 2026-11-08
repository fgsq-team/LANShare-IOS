import Foundation
import CommonCrypto
import CryptoKit

/// AES/ECB/PKCS5Padding + 十六进制编码 (Android: utils/AESUtils.java)
/// 以及文件字节掩码 (Android: utils/mUtil.java encData/decData)
enum LCrypto {
    /// Java padKey：不足 32 字节时以 '\0' 右侧补齐
    static func paddedKey(_ key: String) -> [UInt8] {
        var k = Array(key.utf8)
        if k.count < 32 {
            k.append(contentsOf: [UInt8](repeating: 0, count: 32 - k.count))
        }
        return Array(k.prefix(32))
    }

    static func aesEncrypt(_ data: [UInt8], key: String) -> [UInt8]? {
        crypt(data, key: paddedKey(key), operation: CCOperation(kCCEncrypt))
    }

    static func aesDecrypt(_ data: [UInt8], key: String) -> [UInt8]? {
        crypt(data, key: paddedKey(key), operation: CCOperation(kCCDecrypt))
    }

    private static func crypt(_ data: [UInt8], key: [UInt8], operation: CCOperation) -> [UInt8]? {
        let capacity = max(16, data.count + kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: capacity)
        var outLen = 0
        // 空输入时 CommonCrypto 需要一个非 nil 的指针，长度仍按 0 传入
        let input = data.isEmpty ? [UInt8]([0]) : data
        let status: CCCryptorStatus = input.withUnsafeBytes { dataPtr in
            key.withUnsafeBytes { keyPtr in
                out.withUnsafeMutableBytes { outPtr in
                    CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count, nil,
                            dataPtr.baseAddress, data.count,
                            outPtr.baseAddress, capacity, &outLen)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Array(out[0..<outLen])
    }

    // MARK: - hex

    static func hex(_ bytes: [UInt8]) -> String {
        var s = ""
        s.reserveCapacity(bytes.count * 2)
        for b in bytes { s += String(format: "%02x", b) }
        return s
    }

    static func hexToBytes(_ hex: String) -> [UInt8] {
        let chars = Array(hex)
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i + 1 < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { break }
            out.append(UInt8(hi << 4 | lo))
            i += 2
        }
        return out
    }

    // MARK: - 消息加解密（协议入口）

    /// 对应 Java AESUtils.encrypt(String, String)
    static func encryptMessage(_ text: String, key: String) -> String? {
        guard let enc = aesEncrypt(Array(text.utf8), key: key) else { return nil }
        return hex(enc)
    }

    /// 对应 Java AESUtils.decrypt(String, String)
    static func decryptMessage(_ hexText: String, key: String) -> String? {
        guard let dec = aesDecrypt(hexToBytes(hexText), key: key) else { return nil }
        return String(decoding: dec, as: UTF8.self)
    }

    /// Config.MESSAGE_KEY = AES-decrypt(DEFAULT_MESSAGE_KEY, Config.KEY)
    static func derivedMessageKey() -> String {
        decryptMessage(LConst.defaultMessageKey, key: LConst.key) ?? ""
    }

    // MARK: - MD5

    static func md5Hex(_ string: String) -> String {
        md5Hex(Array(string.utf8))
    }

    static func md5Hex(_ bytes: [UInt8]) -> String {
        hex(Array(Insecure.MD5.hash(data: bytes)))
    }

    // MARK: - 文件传输字节掩码

    static func maskEncData(_ buffer: inout [UInt8], len: Int, off: Int, index: Int64) {
        var j = 0
        for i in off..<(len + off) {
            let v = (Int(buffer[i]) - 1) ^ Int((index + Int64(j)) & 0xFF)
            buffer[i] = UInt8(truncatingIfNeeded: v)
            j += 1
        }
    }

    static func maskDecData(_ buffer: inout [UInt8], len: Int, off: Int, index: Int64) {
        var j = 0
        for i in off..<(len + off) {
            let v = (Int(buffer[i]) ^ Int((index + Int64(j)) & 0xFF)) + 1
            buffer[i] = UInt8(truncatingIfNeeded: v)
            j += 1
        }
    }
}
