import Foundation
import zlib

/// 极简 ZIP 打包 (Android: utils/ZipUtils.java + ZipOutputStream)
/// iOS 端没有 zip 容器 API，这里用 STORE（不压缩）+ crc32 生成合法 zip。
final class LZipWriter {
    private struct Entry {
        let name: String
        let data: Data
        let modTime: UInt16
        let modDate: UInt16
    }

    private var entries: [Entry] = []
    let path: String

    init(path: String) {
        self.path = path
    }

    /// 追加单个文件
    func append(file atPath: String, entryName: String) {
        guard let data = FileManager.default.contents(atPath: atPath) else {
            LLog.debug("zip skip \(atPath)")
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: atPath)
        let date = (attrs?[.modificationDate] as? Date) ?? Date()
        let (time, day) = Self.dosTime(date)
        entries.append(Entry(name: entryName, data: data, modTime: time, modDate: day))
    }

    /// 递归追加目录（对应 compressFiles 的目录展开）
    func appendRecursive(_ root: String, beginIndex: Int) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir) else { return }
        guard isDir.boolValue else {
            guard root.count > beginIndex else { return }
            append(file: root, entryName: String(root.dropFirst(beginIndex)))
            return
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        for name in names.sorted() {
            let full = (root as NSString).appendingPathComponent(name)
            var childIsDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &childIsDir) else { continue }
            if childIsDir.boolValue {
                appendRecursive(full, beginIndex: beginIndex)
            } else if full.count > beginIndex {
                append(file: full, entryName: String(full.dropFirst(beginIndex)))
            }
        }
    }

    /// 写出 zip 文件
    func finish() -> Bool {
        var out = Data()
        var central = Data()
        var offset: UInt32 = 0

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let crc = Self.crc32(entry.data)
            let size = UInt32(entry.data.count)

            var local = Data()
            local.append(le: UInt32(0x0403_4b50))
            local.append(le: UInt16(20))
            local.append(le: UInt16(0))
            local.append(le: UInt16(0)) // STORE
            local.append(le: entry.modTime)
            local.append(le: entry.modDate)
            local.append(le: crc)
            local.append(le: size)
            local.append(le: size)
            local.append(le: UInt16(nameBytes.count))
            local.append(le: UInt16(0))
            local.append(contentsOf: nameBytes)
            local.append(entry.data)

            out.append(local)

            var record = Data()
            record.append(le: UInt32(0x0201_4b50))
            record.append(le: UInt16(20))
            record.append(le: UInt16(20))
            record.append(le: UInt16(0))
            record.append(le: UInt16(0))
            record.append(le: entry.modTime)
            record.append(le: entry.modDate)
            record.append(le: crc)
            record.append(le: size)
            record.append(le: size)
            record.append(le: UInt16(nameBytes.count))
            record.append(le: UInt16(0)) // extra
            record.append(le: UInt16(0)) // comment
            record.append(le: UInt16(0)) // disk
            record.append(le: UInt16(0)) // internal attrs
            record.append(le: UInt32(0)) // external attrs
            record.append(le: offset)
            record.append(contentsOf: nameBytes)

            central.append(record)
            offset += UInt32(local.count)
        }

        let end = Data()
            .appending(le: UInt32(0x0605_4b50))
            .appending(le: UInt16(0))
            .appending(le: UInt16(0))
            .appending(le: UInt16(entries.count))
            .appending(le: UInt16(entries.count))
            .appending(le: UInt32(central.count))
            .appending(le: UInt32(offset))
            .appending(le: UInt16(0))

        out.append(central)
        out.append(end)
        do {
            try out.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            LLog.error("zip write failed: \(error)")
            return false
        }
    }

    static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw -> UInt32 in
            let ptr = raw.bindMemory(to: UInt8.self).baseAddress
            return UInt32(zlib.crc32(0, ptr, uInt(raw.count)))
        }
    }

    /// DOS 时间戳（zip 头使用）
    private static func dosTime(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, c.year ?? 1980)
        let day = UInt16(UInt16(max(1, c.day ?? 1)) | (UInt16(max(1, c.month ?? 1)) << 5)
            | (UInt16(max(0, year - 1980)) << 9))
        let time = UInt16(UInt16((c.second ?? 0) / 2) | (UInt16(c.minute ?? 0) << 5) | (UInt16(c.hour ?? 0) << 11))
        return (time, day)
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(le value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func appending<T: FixedWidthInteger>(le value: T) -> Data {
        var copy = self
        copy.append(le: value)
        return copy
    }
}
