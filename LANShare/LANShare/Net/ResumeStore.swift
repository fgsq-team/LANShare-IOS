import Foundation

/// 接收文件写入 (Android: FileOutputStream / IOUtil)
final class LFileWriter {
    let path: String
    private var fd: Int32
    var offset: Int64

    init(path: String, append: Bool, offset: Int64 = 0) throws {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let flags = append ? (O_WRONLY | O_CREAT | O_APPEND) : (O_WRONLY | O_CREAT | O_TRUNC)
        fd = open(path, flags, 0o644)
        guard fd >= 0 else { throw LSError.io("open \(path) failed: \(String(cString: strerror(errno)))") }
        self.offset = append ? offset : 0
        if !append, offset > 0 {
            // 追加模式由 O_APPEND 保证，截断模式不应带偏移
            self.offset = 0
        }
    }

    func write(_ data: [UInt8]) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { raw in
            var sent = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while sent < data.count {
                let n = Darwin.write(fd, base + sent, data.count - sent)
                if n > 0 { sent += n; continue }
                if n < 0, errno == EINTR { continue }
                throw LSError.io("write failed: \(String(cString: strerror(errno)))")
            }
        }
        offset += Int64(data.count)
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { close() }
}

/// 读取本地文件用于发送
final class LFileReader {
    private var fd: Int32
    let length: Int64
    private(set) var offset: Int64 = 0
    /// 流式来源（网页上传转发等）
    private var streamSource: (() -> [UInt8]?)?
    /// 流式来源单次读到的量可能大于本次请求量，余下字节留到下次读取：
    /// 续传偏移必须精确丢字节，否则会把还没发的数据读丢 (Android: ResumeStore.skipFully)
    private var pending: [UInt8] = []

    init(path: String) throws {
        fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw LSError.io("open \(path) failed") }
        length = lseek(fd, 0, SEEK_END)
        lseek(fd, 0, SEEK_SET)
    }

    init(stream: @escaping () -> [UInt8]?) {
        fd = -1
        length = -1
        streamSource = stream
    }

    /// 对应 ResumeStore.skipFully
    func skip(to target: Int64) throws {
        guard streamSource != nil else {
            let pos = lseek(fd, off_t(target), SEEK_SET)
            guard pos >= 0 else { throw LSError.io("seek failed") }
            offset = target
            return
        }
        // 流式来源无法跳传，读取并丢弃；read() 自己会推进 offset，这里不能重复累加
        while offset < target {
            guard let chunk = read(Int(target - offset)), !chunk.isEmpty else { return }
            _ = chunk
        }
    }

    func read(_ maxLen: Int) -> [UInt8]? {
        if streamSource != nil {
            if pending.isEmpty, let chunk = streamSource?() {
                pending = chunk
            }
            guard maxLen > 0, !pending.isEmpty else { return nil }
            let out = Array(pending[0..<min(maxLen, pending.count)])
            pending.removeFirst(out.count)
            offset += Int64(out.count)
            return out
        }
        var buffer = [UInt8](repeating: 0, count: maxLen)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, maxLen) }
        if n <= 0 { return n == 0 ? nil : nil }
        offset += Int64(n)
        return Array(buffer[0..<n])
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { close() }
}

/// V5 断点续传分段存储 (Android: service/version/five/ResumeStore.java)
enum ResumeStore {
    static let resumeDirName = ".lanshare_resume"
    static let partSuffix = ".part"
    static let targetMarker = ".target"
    static let partExpireMs: Int64 = 7 * 24 * 60 * 60 * 1000

    /// 基于种子生成稳定 fileId：MD5("LRESUME:" + seed)
    static func stableId(seed: String) -> String {
        LCrypto.md5Hex("LRESUME:" + seed)
    }

    static var partRoot: String {
        let root = (LSettings.shared.fileSavePath as NSString).appendingPathComponent(resumeDirName)
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    static func filePart(_ fileId: String) -> String {
        (partRoot as NSString).appendingPathComponent(fileId + partSuffix)
    }

    static func folderStageDir(_ folderFileId: String) -> String {
        let dir = (partRoot as NSString).appendingPathComponent(folderFileId)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static func childPart(folderFileId: String, childFileId: String) -> String {
        ((folderStageDir(folderFileId)) as NSString).appendingPathComponent(childFileId + partSuffix)
    }

    static func fileSize(_ path: String) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    /// 分段已完成字节数，超过总长视为损坏
    static func readOffset(_ part: String, total: Int64) -> Int64 {
        guard FileManager.default.fileExists(atPath: part) else { return 0 }
        let len = fileSize(part)
        if len > total {
            try? FileManager.default.removeItem(atPath: part)
            return 0
        }
        return len
    }

    static func openAppendWriter(_ part: String, offset: Int64) throws -> LFileWriter {
        try LFileWriter(path: part, append: true, offset: offset)
    }

    /// 分段落地为最终文件
    static func finalizePart(_ part: String, to destination: String) -> String {
        let target = FileUtil.avoidDuplication(destination)
        try? FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target) {
            try? FileManager.default.removeItem(atPath: target)
        }
        do {
            try FileManager.default.moveItem(atPath: part, toPath: target)
        } catch {
            LLog.error("finalize part failed \(error)")
        }
        return target
    }

    /// 文件夹分段移动到最终目录下的相对路径
    static func movePartToFinal(_ part: String, finalDir: String, relativeName: String) {
        let dest = (finalDir as NSString).appendingPathComponent(relativeName)
        try? FileManager.default.createDirectory(atPath: (dest as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest) {
            try? FileManager.default.removeItem(atPath: dest)
        }
        try? FileManager.default.moveItem(atPath: part, toPath: dest)
    }

    static func writeTarget(_ stage: String, _ path: String) {
        let marker = (stage as NSString).appendingPathComponent(targetMarker)
        try? path.data(of: .utf8)?.write(to: URL(fileURLWithPath: marker))
    }

    static func readTarget(_ stage: String) -> String? {
        let marker = (stage as NSString).appendingPathComponent(targetMarker)
        return try? String(contentsOfFile: marker, encoding: .utf8)
    }

    static func deleteDir(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// 清理超过 7 天的分段
    static func cleanupExpired() {
        let root = partRoot
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        let now = Date()
        for item in items {
            let full = (root as NSString).appendingPathComponent(item)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: full),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if now.timeIntervalSince(mtime) * 1000 > Double(partExpireMs) {
                try? FileManager.default.removeItem(atPath: full)
            }
        }
    }
}

private extension String {
    func data(of encoding: String.Encoding) -> Data? {
        data(using: encoding)
    }
}

/// 文件辅助 (Android: utils/FileUtil.java 部分能力)
enum FileUtil {
    /// 去重命名 name(1).ext
    static func avoidDuplication(_ path: String) -> String {
        guard FileManager.default.fileExists(atPath: path) else { return path }
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        let hasExt = name.contains(".")
        let prefix = hasExt ? String(name[..<name.lastIndex(of: ".")!]) : name
        let suffix = hasExt ? String(name[name.lastIndex(of: ".")!...]) : ""
        for i in 1..<65535 {
            let candidate = (parent as NSString).appendingPathComponent("\(prefix)(\(i))\(suffix)")
            if !FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return path
    }

    /// 分类目录 (Android: FileUtil.classifyFile)
    static func classifyFile(base: String, category: String) -> String {
        LSettings.shared.saveFilesCategory ? (base as NSString).appendingPathComponent(category) : base
    }

    static func sizeText(_ size: Int64) -> String {
        MessageFileContent.formatSize(size)
    }

    static func modificationDateText(_ path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}
