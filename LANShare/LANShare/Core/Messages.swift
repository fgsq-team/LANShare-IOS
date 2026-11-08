import Foundation
import SwiftUI
import Combine

/// 消息基类 (Android: pojo/message/MessageContent.java)
class MessageContent: ObservableObject, Identifiable {
    var id: String
    @Published var content: String
    @Published var isLeft: Bool
    var devMode: Int32
    var userName: String
    var toUser: String
    var createTime: Date
    @Published var status: Int
    var dataVersion: Int32
    @Published var checked: Bool = false
    @Published var textSelection: Bool = false

    /// 数据库 messageType：-1 时间分隔 / 1 文本 / 2 媒体 / 3 文件 / 4 位置
    var messageType: Int { 1 }

    init(id: String = MessageContent.newId(), content: String = "", isLeft: Bool = false) {
        self.id = id
        self.content = content
        self.isLeft = isLeft
        devMode = DevMode.unknow.rawValue
        userName = ""
        toUser = ""
        createTime = Date()
        status = MessageStatus.inProgress
        dataVersion = Int32(LConst.dataVersion)
    }

    static func newId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    var isFinal: Bool {
        status & MessageStatus.success != 0 || status & MessageStatus.error != 0
    }

    var isError: Bool { status & MessageStatus.error != 0 }
    var isSuccess: Bool { status & MessageStatus.success != 0 }
}

/// 文本消息
final class MessageTextContent: MessageContent {
    override var messageType: Int { 1 }
    var isClip: Bool = false
}

/// 文件消息 (Android: MessageFileContent.java)
class MessageFileContent: MessageContent {
    static let fileTypeImage = 0x1
    static let fileTypeVideo = 0x2
    static let fileTypeAudio = 0x3
    static let fileTypeApk = 0x4
    static let fileTypeFile = 0x5
    static let fileTypeFolder = 0x6
    static let fileTypeDownloadInfo = 0x7
    static let fileTypeStream = 0x8
    static let fileTypeUri = 0x9

    @Published var fileId: String
    @Published var fileType: Int
    @Published var progress: Int = 0
    var path: String
    var length: Int64
    @Published var completedSize: Int64 = 0
    var index: Int
    @Published var stateMessage: String
    var time: Int64
    @Published var isTransfer: Bool = true
    var isGif: Bool = false

    /// 接收端持有，用于向发送端回写取消指令 (Android: MessageFileContent.outputStream)
    var cancelStream: LTcpStream?

    /// 取消该文件的传输：本地置位 + 通过连接反向通道告知对端
    func cancelTransfer() {
        isTransfer = false
        guard let stream = cancelStream else { return }
        LThread.run {
            do {
                try stream.writeString(self.fileId)
                LThread.main { LANService.shared.showToast("已取消传输") }
            } catch {
                LLog.debug("cancel transfer write failed: \(error)")
            }
        }
    }

    override var messageType: Int { 3 }

    /// 展示名（对应 Android 的 name，即 content）
    var name: String {
        get { content }
        set { content = newValue }
    }

    init(fileId: String = "", fileType: Int = MessageFileContent.fileTypeFile,
         name: String = "", path: String = "", length: Int64 = 0) {
        self.fileId = fileId
        self.fileType = fileType
        self.path = path
        self.length = length
        self.index = 0
        self.time = 0
        self.stateMessage = ""
        super.init(content: name)
    }

    var isFolder: Bool { fileType == MessageFileContent.fileTypeFolder }
    var isMedia: Bool { fileType == MessageFileContent.fileTypeImage || fileType == MessageFileContent.fileTypeVideo }

    var sizeText: String {
        if isFolder { return "\(Self.formatSize(length))・\(folderCount)项" }
        return Self.formatSize(length)
    }

    var folderCount: Int { (self as? MessageFolderContent)?.fileCount ?? 0 }

    static func formatSize(_ size: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB, .useBytes]
        return f.string(fromByteCount: size)
    }

    var fileURL: URL? {
        path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// 发送前深拷贝 (Android: mUtil.deepCopyList)
    func deepCopy() -> MessageFileContent {
        let copy: MessageFileContent
        if let folder = self as? MessageFolderContent {
            let item = MessageFolderContent()
            item.fileCount = folder.fileCount
            item.children = folder.children.map { child in
                let c = child.deepCopy()
                return c
            }
            copy = item
        } else if let media = self as? MessageMediaContent {
            let item = MessageMediaContent(isVideo: media.isVideo, videoTime: media.videoTime)
            item.mediaId = media.mediaId
            item.isLivePhoto = media.isLivePhoto
            item.liveVideoPath = media.liveVideoPath
            item.assetIdentifier = media.assetIdentifier
            copy = item
        } else {
            copy = MessageFileContent()
        }
        copy.id = id
        copy.fileId = fileId
        copy.fileType = fileType
        copy.content = content
        copy.path = path
        copy.length = length
        copy.index = index
        copy.time = time
        copy.progress = progress
        copy.completedSize = completedSize
        copy.stateMessage = stateMessage
        copy.isGif = isGif
        copy.isTransfer = isTransfer
        copy.isLeft = isLeft
        copy.userName = userName
        copy.toUser = toUser
        copy.devMode = devMode
        copy.dataVersion = dataVersion
        copy.status = status
        copy.createTime = createTime
        return copy
    }
}

/// 图片/视频 (Android: MessageMediaContent.java)
final class MessageMediaContent: MessageFileContent {
    @Published var isVideo: Bool
    @Published var videoTime: String
    var mediaId: Int64 = -1
    var isLivePhoto: Bool = false
    var liveVideoPath: String?

    /// 图片缩略图（沙盒内路径或相册 localIdentifier）
    var assetIdentifier: String?

    override var messageType: Int { 2 }

    init(isVideo: Bool = false, videoTime: String = "") {
        self.isVideo = isVideo
        self.videoTime = videoTime
        super.init(fileType: isVideo ? MessageFileContent.fileTypeVideo : MessageFileContent.fileTypeImage)
    }
}

/// 文件夹 (Android: MessageFolderContent.java)
final class MessageFolderContent: MessageFileContent {
    @Published var fileCount: Int = 0
    @Published var completeCount: Int = 0
    var children: [MessageFileContent] = []

    init() {
        super.init(fileType: MessageFileContent.fileTypeFolder)
    }
}

/// 应用（Android 的 APK；iOS 上仅用于网页端/对端下发的应用条目展示）
final class MessageApkContent: MessageFileContent {
    var packageName: String = ""
    var versionName: String = ""
    var versionCode: Int = 0

    init() {
        super.init(fileType: MessageFileContent.fileTypeApk)
    }
}

/// 音频
final class MessageAudioContent: MessageFileContent {
    var musicMediaId: Int64 = -1
    var musicTime: String = ""

    init() {
        super.init(fileType: MessageFileContent.fileTypeAudio)
    }
}

/// 位置消息 (Android: MessageGPSContent.java)
final class MessageGPSContent: MessageContent {
    /// 1=高德 2=百度 3=腾讯 4=Google
    var type: Int = 4
    var latitude: String = ""
    var longitude: String = ""
    var address: String = ""
    var placeName: String = ""

    override var messageType: Int { 4 }

    var jsonObject: [String: Any] {
        ["type": type, "latitude": latitude, "longitude": longitude, "address": address, "name": placeName]
    }

    var jsonString: String {
        guard let d = try? JSONSerialization.data(withJSONObject: jsonObject),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    static func from(jsonString: String) -> MessageGPSContent? {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let g = MessageGPSContent()
        g.type = obj["type"] as? Int ?? 4
        g.latitude = "\(obj["latitude"] ?? "")"
        g.longitude = "\(obj["longitude"] ?? "")"
        g.address = obj["address"] as? String ?? ""
        g.placeName = obj["name"] as? String ?? ""
        g.content = g.placeName.isEmpty ? g.address : g.placeName
        return g
    }
}

/// 流式来源（网页上传转发到设备）(Android: MessageStreamContent.java)
final class MessageStreamContent: MessageFileContent {
    /// 每次调用返回下一段数据，返回 nil 表示结束
    var source: (() -> [UInt8]?)?

    init(name: String = "", length: Int64 = -1) {
        super.init(fileType: MessageFileContent.fileTypeStream, name: name, length: length)
    }
}

/// 分享导入的 URL (Android: MessageUriContent.java)
final class MessageUriContent: MessageFileContent {
    var url: URL?

    init(url: URL?) {
        self.url = url
        let name = url?.lastPathComponent ?? "shared"
        super.init(fileType: MessageFileContent.fileTypeUri, name: name)
    }

    /// 拷贝到沙盒临时目录以便发送
    func materialize() -> String? {
        guard let url else { return nil }
        let fm = FileManager.default
        if url.isFileURL, fm.fileExists(atPath: url.path) {
            // 沙盒内可直接使用
            let docs = fm.documentsDirectory
            if url.path.hasPrefix(fm.temporaryDirectory.path) || url.path.hasPrefix(docs) {
                return url.path
            }
            let dest = fm.temporaryDirectory.appendingPathComponent(url.lastPathComponent).path
            try? fm.removeItem(atPath: dest)
            if (try? fm.copyItem(atPath: url.path, toPath: dest)) != nil { return dest }
            return url.path
        }
        return url.path
    }
}

private extension FileManager {
    var documentsDirectory: String {
        (NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? "") as String
    }
}

/// 时间分隔 (Android: MessageTimeContent.java)
final class MessageTimeContent: MessageContent {
    var bindId: String = ""
    override var messageType: Int { -1 }

    init(time: Date = Date(), bindId: String = "") {
        super.init(id: "time_" + bindId, content: "")
        createTime = time
        self.bindId = bindId
    }
}
