import Foundation

/// 协议版本 (Android: config/LVersion.java)
enum LVersion {
    static let dataVersion1 = 1
    static let dataVersion2 = 2
    static let dataVersion3 = 3
    static let dataVersion4 = 4
    static let dataVersion5 = 5
}

/// 通讯命令 (Android: constants/LCmd.java)
enum LCmd {
    static let newVersion4: Int32 = -2
    static let newVersion5: Int32 = -3

    static let udpGetDevices: Int32 = 1001
    static let udpSetDevices: Int32 = 1002
    static let udpDevicesOffLine: Int32 = 1003
    static let udpDevicesMessage: Int32 = 1004
    static let udpDevicesMessageToClipboard: Int32 = 1005
    static let udpSendMediaMute: Int32 = 1006
    static let udpSendMediaRestore: Int32 = 1007
    static let udpSendMediaPause: Int32 = 1008
    static let udpSendMediaNext: Int32 = 1009
    static let udpSendMediaPrevious: Int32 = 1010
    static let udpSendMap: Int32 = 1011

    static let fsShareFile: Int32 = 1101
    static let fsAgree: Int32 = 1102
    static let fsNotAgree: Int32 = 1103
    static let fsAddDevice: Int32 = 1104
    static let fsMessage: Int32 = 1105
    static let fsGetNoSyncMedia: Int32 = 1106
    static let fsSyncMedia: Int32 = 1107
    static let fsUpdateApps: Int32 = 1108
    static let fsGetApps: Int32 = 1109
    static let fsDraw: Int32 = 1110
    static let fsDrawSyncRequest: Int32 = 1111
    static let fsDrawSyncAccept: Int32 = 1112
    static let fsDrawSyncReject: Int32 = 1113

    static let fsData: UInt8 = 1
    static let fsEnd: UInt8 = 2
    static let fsClose: UInt8 = 3
    static let fsDataReceived: UInt8 = 4
    static let fsNext: Int32 = 5
    static let fsBreak: Int32 = 6
    static let newFsBreak: Int32 = -2

    static let fileImage: Int32 = 3001
    static let fileViedo: Int32 = 3002
    static let fileFile: Int32 = 3003
    static let fileFolder: Int32 = 3004
    static let fileMessageToClip: Int32 = 3006
}

/// WebSocket 命令 (Android: constants/WSCmd.java)
enum WSCmd {
    static let sendMessage: Int = 1
    static let syncDeviceList: Int = 2
    static let changeTheme: Int = 3
    static let drawEvent: Int = 4
    static let ping: Int = 5
    static let pong: Int = 6
}

/// 消息状态位 (Android: pojo/message/MessageContent.java)
enum MessageStatus {
    static let inProgress = 0x2
    static let success = 0x4
    static let error = 0x8
    static let fileNotExist = 0x10
}

/// 全局常量 (Android: config/Config.java)
enum LConst {
    static let defaultFileServerPort = 5856
    static let defaultUdpPort = 4573
    static let appName = "LANShare"
    static let key = "6c9b%8ErII@Rc&f"
    static let defaultMessageKey = "e4be1373272c69e0932651d97187b746c6725b17bbe84ad0b0fe2d4e81fc1d6c0c633d8ebd7f0fea65a57a9d5529d214"
    static let magicNum: Int32 = 0x6667_7371
    static let dataVersion = LVersion.dataVersion5
    static let privacyVersion = 1
    static let scanInterval: TimeInterval = 5
    static let deviceTimeoutMs: Int64 = 20_000
    static let defaultFileSavePath = "LANShare"
    static let folderLabel = "文件夹"
    static let allDevicesKey = "所有设备"
    static let server = "http://lanshares.com"
    static let github = "https://github.com/fgsq-team/LANShare"

    /// UDP 单包可承载的最大明文字符数，超过则走 TCP FS_MESSAGE
    static let udpMessageCharLimit = 700

    /// 文件后缀分类 (Android: Config.fileTypes)
    static let fileTypes: [(ext: String, category: String)] = [
        ("zip", "压缩包"), ("rar", "压缩包"), ("7z", "压缩包"),
        ("apk", "软件"),
        ("mp4", "视频"), ("avi", "视频"), ("rmvb", "视频"), ("3gp", "视频"),
        ("aac", "音频"), ("m4a", "音频"), ("ape", "音频"), ("flac", "音频"), ("wav", "音频"),
        ("png", "图片"), ("jpg", "图片"), ("jpeg", "图片"), ("gif", "图片"),
        ("txt", "文档"), ("doc", "文档"), ("docx", "文档"), ("obt", "文档"),
        ("xls", "表格"), ("xlsx", "表格"),
    ]

    static func category(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return fileTypes.first { $0.ext == ext }?.category ?? "其他"
    }
}

/// 设备类型 (Android: pojo/Device.java)
enum DevMode: Int32 {
    case unknow = -1
    case android = 1
    case windows = 2
    case linux = 3
    case macOs = 4
    case ios = 5
    case harmonyOs = 6
    case web = 7
}
