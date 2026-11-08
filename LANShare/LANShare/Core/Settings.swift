import Foundation
import Combine
import SwiftUI

/// 偏好设置键 (Android: config/PreConfig.java)
enum PreKey {
    static let themeMode = "theme_mode"
    static let filePath = "filePath"
    static let userName = "userName"
    static let openMediaOnInternalPlayer = "open_media_on_internal_player"
    static let notRecvDialog = "not_recv_dialog"
    static let mediaSelectModel = "media_select_model"
    static let saveMessage = "save_message"
    static let privacyAgree = "privacy_agree"
    static let privacyVersion = "privacy_version"
    static let saveToGallery = "save_to_gallery"
    static let showHiddenFiles = "show_hidden_files"
    static let tcpPort = "tcpPort"
    static let udpPort = "udpPort"
    static let autoStart = "auto_start"
    static let broadcastMessage = "broadcast_message"
    static let receiveBroadcastMessages = "receive_broadcast_messages"
    static let sendMute = "send_mute"
    static let receiveMute = "receivce_mute"
    static let messageKey = "message_key"
    static let uniqueUUid = "unique_uuid"
    static let encData = "enc_data"
    static let webService = "web_serviec"
    static let syncNotification = "sync_notification"
    static let webOpen = "web_open"
    static let messageNotification = "message_notification"
    static let lastFilePath = "last_file_path"
    static let saveLastFilePath = "s_last_file_path"
    static let saveFilesCategory = "save_files_category"
    static let mediaSync = "media_sync"
    static let noUpdateVersion = "no_update_version"
    static let activityTopMargin = "activity_top_margin"
    static let fileSortMethod = "file_sort_method"
    static let searchFileTypes = "search_file_types"
    static let defaultSelectOnlyOneDevice = "setting_default_select_only_one_device_switch"
}

enum ThemeMode: String, CaseIterable, Identifiable {
    case light, dark, emerald, followSystem = "follow_system"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light: return "光明"
        case .dark: return "暗黑"
        case .emerald: return "翠绿"
        case .followSystem: return "跟随系统"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .light, .emerald: return .light
        case .dark: return .dark
        case .followSystem: return nil
        }
    }
    /// 与网页端 / Android 的 theme 字符串保持一致
    var webTheme: String { rawValue }
}

/// 文件排序方式 (Android: PreConfig.FILE_SORT_METHOD 0..5)
enum FileSortMethod: Int, CaseIterable, Identifiable {
    case nameAsc = 0, nameDesc, timeAsc, timeDesc, sizeAsc, sizeDesc
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .nameAsc: return "名称升序"
        case .nameDesc: return "名称降序"
        case .timeAsc: return "时间升序"
        case .timeDesc: return "时间降序"
        case .sizeAsc: return "大小升序"
        case .sizeDesc: return "大小降序"
        }
    }
}

/// 运行期配置 (Android: config/Config.java + App.getPrefUtil())
final class LSettings: ObservableObject {
    static let shared = LSettings()

    private let d = UserDefaults.standard

    @Published var devName: String { didSet { d.set(devName, forKey: PreKey.userName) } }
    @Published var themeMode: ThemeMode { didSet { d.set(themeMode.rawValue, forKey: PreKey.themeMode) } }
    @Published var relativeFilePath: String { didSet { d.set(relativeFilePath, forKey: PreKey.filePath) } }
    @Published var tcpPort: Int { didSet { d.set(tcpPort, forKey: PreKey.tcpPort) } }
    @Published var udpPort: Int { didSet { d.set(udpPort, forKey: PreKey.udpPort) } }
    @Published var notRecvDialog: Bool { didSet { d.set(notRecvDialog, forKey: PreKey.notRecvDialog) } }
    @Published var openMediaOnInternalPlayer: Bool { didSet { d.set(openMediaOnInternalPlayer, forKey: PreKey.openMediaOnInternalPlayer) } }
    @Published var mediaSelectModel: Bool { didSet { d.set(mediaSelectModel, forKey: PreKey.mediaSelectModel) } }
    @Published var saveMessage: Bool { didSet { d.set(saveMessage, forKey: PreKey.saveMessage) } }
    @Published var saveToGallery: Bool { didSet { d.set(saveToGallery, forKey: PreKey.saveToGallery) } }
    @Published var showHiddenFiles: Bool { didSet { d.set(showHiddenFiles, forKey: PreKey.showHiddenFiles) } }
    @Published var encData: Bool { didSet { d.set(encData, forKey: PreKey.encData) } }
    @Published var webService: Bool { didSet { d.set(webService, forKey: PreKey.webService) } }
    @Published var webOpen: Bool { didSet { d.set(webOpen, forKey: PreKey.webOpen) } }
    @Published var messageNotification: Bool { didSet { d.set(messageNotification, forKey: PreKey.messageNotification) } }
    @Published var saveLastFilePath: Bool { didSet { d.set(saveLastFilePath, forKey: PreKey.saveLastFilePath) } }
    @Published var saveFilesCategoryPref: Bool { didSet { d.set(saveFilesCategoryPref, forKey: PreKey.saveFilesCategory) } }
    @Published var mediaSync: Bool { didSet { d.set(mediaSync, forKey: PreKey.mediaSync) } }
    @Published var defaultSelectOnlyOneDevice: Bool { didSet { d.set(defaultSelectOnlyOneDevice, forKey: PreKey.defaultSelectOnlyOneDevice) } }
    @Published var broadcastMessage: Bool { didSet { d.set(broadcastMessage, forKey: PreKey.broadcastMessage) } }
    @Published var receiveBroadcastMessages: Bool { didSet { d.set(receiveBroadcastMessages, forKey: PreKey.receiveBroadcastMessages) } }
    @Published var fileSortMethod: FileSortMethod { didSet { d.set(fileSortMethod.rawValue, forKey: PreKey.fileSortMethod) } }
    @Published var topMargin: Int { didSet { d.set(topMargin, forKey: PreKey.activityTopMargin) } }
    @Published var searchFlags: [Bool] { didSet { d.set(searchFlags, forKey: PreKey.searchFileTypes) } }
    /// 自定义消息密钥（存放的是加密后的 hex，与 Android 一致）
    @Published var messageKeyCipher: String { didSet { d.set(messageKeyCipher, forKey: PreKey.messageKey) } }

    let uniqueUUid: String
    let privacyAgreed: Bool

    /// 解密后的实际消息密钥
    var messageKey: String {
        LCrypto.decryptMessage(messageKeyCipher, key: LConst.key) ?? LCrypto.derivedMessageKey()
    }

    /// 文件保存路径 (Android: Environment.getExternalStorageDirectory() + filePath)
    var fileSavePath: String {
        let base = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        var rel = relativeFilePath
        while rel.hasPrefix("/") { rel.removeFirst() }
        if rel.isEmpty { rel = LConst.defaultFileSavePath }
        return (base as NSString).appendingPathComponent(rel) + "/"
    }

    private init() {
        d.register(defaults: [
            PreKey.filePath: LConst.defaultFileSavePath,
            PreKey.tcpPort: LConst.defaultFileServerPort,
            PreKey.udpPort: LConst.defaultUdpPort,
            PreKey.notRecvDialog: true,
            PreKey.openMediaOnInternalPlayer: true,
            PreKey.saveMessage: true,
            PreKey.saveToGallery: true,
            PreKey.webService: true,
            PreKey.webOpen: false,
            PreKey.messageNotification: false,
            PreKey.saveLastFilePath: false,
            PreKey.saveFilesCategory: false,
            PreKey.mediaSync: false,
            PreKey.defaultSelectOnlyOneDevice: false,
            PreKey.themeMode: ThemeMode.followSystem.rawValue,
            PreKey.fileSortMethod: 0,
            PreKey.activityTopMargin: 0,
        ])
        var name = d.string(forKey: PreKey.userName) ?? ""
        if name.isEmpty {
            name = DeviceIdentity.modelName
            d.set(name, forKey: PreKey.userName)
        }
        devName = name
        themeMode = ThemeMode(rawValue: d.string(forKey: PreKey.themeMode) ?? "follow_system") ?? .followSystem
        relativeFilePath = d.string(forKey: PreKey.filePath) ?? LConst.defaultFileSavePath
        tcpPort = d.integer(forKey: PreKey.tcpPort)
        udpPort = d.integer(forKey: PreKey.udpPort)
        notRecvDialog = d.bool(forKey: PreKey.notRecvDialog)
        openMediaOnInternalPlayer = d.bool(forKey: PreKey.openMediaOnInternalPlayer)
        mediaSelectModel = d.bool(forKey: PreKey.mediaSelectModel)
        saveMessage = d.bool(forKey: PreKey.saveMessage)
        saveToGallery = d.bool(forKey: PreKey.saveToGallery)
        showHiddenFiles = d.bool(forKey: PreKey.showHiddenFiles)
        encData = d.bool(forKey: PreKey.encData)
        webService = d.bool(forKey: PreKey.webService)
        webOpen = d.bool(forKey: PreKey.webOpen)
        messageNotification = d.bool(forKey: PreKey.messageNotification)
        saveLastFilePath = d.bool(forKey: PreKey.saveLastFilePath)
        saveFilesCategoryPref = d.bool(forKey: PreKey.saveFilesCategory)
        mediaSync = d.bool(forKey: PreKey.mediaSync)
        defaultSelectOnlyOneDevice = d.bool(forKey: PreKey.defaultSelectOnlyOneDevice)
        broadcastMessage = d.bool(forKey: PreKey.broadcastMessage)
        receiveBroadcastMessages = d.bool(forKey: PreKey.receiveBroadcastMessages)
        fileSortMethod = FileSortMethod(rawValue: d.integer(forKey: PreKey.fileSortMethod)) ?? .nameAsc
        topMargin = d.integer(forKey: PreKey.activityTopMargin)
        searchFlags = (d.array(forKey: PreKey.searchFileTypes) as? [Bool]) ?? [true, true, true, true]
        messageKeyCipher = d.string(forKey: PreKey.messageKey) ?? LConst.defaultMessageKey

        var uuid = d.string(forKey: PreKey.uniqueUUid) ?? ""
        if uuid.isEmpty {
            uuid = MessageContent.newId()
            d.set(uuid, forKey: PreKey.uniqueUUid)
        }
        uniqueUUid = uuid
        privacyAgreed = d.bool(forKey: PreKey.privacyAgree)
                && d.integer(forKey: PreKey.privacyVersion) == LConst.privacyVersion
    }

    /// 对应 Config.SAVE_FILES_CATEGORY = !pref(save_files_category)
    var saveFilesCategory: Bool { !saveFilesCategoryPref }

    func markPrivacyAgreed() {
        d.set(true, forKey: PreKey.privacyAgree)
        d.set(LConst.privacyVersion, forKey: PreKey.privacyVersion)
    }
}

enum DeviceIdentity {
    /// 设备名默认值 (Android: Build.MODEL)
    static var modelName: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        if machine.isEmpty { return "iOS Device" }
        return machine
    }
}
