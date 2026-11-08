import SwiftUI
import Combine
import UIKit
import AVFoundation
import AVKit
import QuickLook
import Photos

// MARK: - 主题 (Android: theme 光明/暗黑/翠绿) —— 令牌见 Theme.swift

// MARK: - 全局 UI 状态

/// 设备选择请求；由 RootView 统一呈现弹窗 (Android: DeviceSelectDialog / FileSendDialog)
struct DevicePickerRequest: Identifiable {
    let id = UUID()
    let title: String
    let showAllDevices: Bool
    let completion: (Device?) -> Void
}

final class LAppModel: ObservableObject {
    static let shared = LAppModel()

    /// 聊天目标；nil 表示所有设备 (Android: chat_dev_select_tv)
    @Published var chatTarget: Device?
    @Published var devicePicker: DevicePickerRequest?
    @Published var quickLook: [URL] = []
    @Published var showQuickLook = false
    @Published var imagePages: [ImagePage] = []
    @Published var imageIndex = 0
    @Published var showImagePreview = false
    @Published var videoPreview: IdentifiableURL?

    private init() {}

    func pickDevice(title: String = "请选择需要发送的设备", showAllDevices: Bool = true,
                    _ completion: @escaping (Device?) -> Void) {
        devicePicker = DevicePickerRequest(title: title, showAllDevices: showAllDevices, completion: completion)
    }

    func preview(_ url: URL) {
        quickLook = [url]
        showQuickLook = true
    }

    func previewImages(paths: [String], index: Int = 0) {
        imagePages = paths.map { ImagePage.file($0) }
        imageIndex = min(max(index, 0), max(paths.count - 1, 0))
        showImagePreview = !paths.isEmpty
    }

    /// 相册翻页预览：只取图片，直接按显示尺寸取图，不必先把原图导出到沙盒
    func previewAssets(_ assets: [PHAsset], index: Int) {
        let images = assets.filter { $0.mediaType == .image }
        guard !images.isEmpty else { return }
        imagePages = images.map { ImagePage.photo($0) }
        let currentId = assets.indices.contains(index) ? assets[index].localIdentifier : nil
        imageIndex = max(0, images.firstIndex { $0.localIdentifier == currentId } ?? 0)
        showImagePreview = true
    }

    func copyToPasteboard(_ text: String) {
        UIPasteboard.general.string = text
        LANService.shared.showToast("已复制")
    }

    func previewVideo(_ url: URL) {
        videoPreview = IdentifiableURL(url)
    }
}

/// fullScreenCover(item:) 需要 Identifiable 包装
struct IdentifiableURL: Identifiable, Hashable {
    let url: URL
    init(_ url: URL) { self.url = url }
    var id: String { url.path }
}

// MARK: - Toast (Android: ToastUtils)

struct LToastModifier: ViewModifier {
    @ObservedObject var service: LANService
    @State private var visible = false
    @State private var text = ""
    @State private var lastId = 0

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if visible {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.75), in: Capsule())
                    .padding(.bottom, 90)
                    .transition(.opacity)
            }
        }
        .onChange(of: service.toastId) { _, newValue in
            guard newValue != lastId else { return }
            lastId = newValue
            text = service.toastText
            withAnimation(.easeIn(duration: 0.15)) { visible = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeOut(duration: 0.2)) { visible = false }
            }
        }
    }
}

extension View {
    func lanToast(_ service: LANService) -> some View {
        modifier(LToastModifier(service: service))
    }

    /// 长按复制（用于 IP、设备名等）
    func copyOnLongPress(_ text: String) -> some View {
        onLongPressGesture { LAppModel.shared.copyToPasteboard(text) }
    }
}

// MARK: - 沙盒文件浏览 (Android: FragmentFileList / FileUtils)

struct FileEntry: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var sizeText: String { isDirectory ? "" : MessageFileContent.formatSize(size) }
    var isHidden: Bool { name.hasPrefix(".") }
    var category: String { LConst.category(for: name) }

    var systemIcon: String {
        if isDirectory { return "folder" }
        switch category {
        case "图片": return "photo"
        case "视频": return "movie"
        case "音频": return "music.note"
        case "压缩包": return "doc.zipper"
        case "文档", "表格": return "doc.text"
        default: return "doc"
        }
    }
}

enum LFileStore {
    /// iOS 只能浏览本应用沙盒 Documents（对应 Android 的外部存储根）
    static var root: String {
        NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
    }

    static func displayName(_ path: String) -> String {
        let base = (path as NSString).lastPathComponent
        if path == root { return "我的文件" }
        return base
    }

    /// 入库用相对 Documents 的路径：容器 UUID 每次重装都会变，绝对路径整批失效，
    /// 消息列表里的文件就全成了「文件不存在」
    static func stored(_ path: String) -> String {
        let prefix = root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    static func resolved(_ path: String) -> String {
        guard path.hasPrefix("/") else {
            return (root as NSString).appendingPathComponent(path)
        }
        if FileManager.default.fileExists(atPath: path) { return path }
        // 兼容旧库里带 UUID 的绝对路径，按 Documents 之下的相对位置重新拼回去
        guard let range = path.range(of: "/Documents/") else { return path }
        let candidate = (root as NSString).appendingPathComponent(String(path[range.upperBound...]))
        return FileManager.default.fileExists(atPath: candidate) ? candidate : path
    }

    static func parent(of path: String) -> String? {
        guard path != root else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.count >= root.count ? parent : root
    }

    static func entries(in dir: String, showHidden: Bool, sort: FileSortMethod) -> [FileEntry] {
        let fm = FileManager.default
        var list: [FileEntry] = []
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        for name in names {
            if name.hasPrefix(".") && !showHidden { continue }
            let full = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            let attrs = try? fm.attributesOfItem(atPath: full)
            let size = isDir.boolValue ? 0 : (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attrs?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            list.append(FileEntry(name: name, path: full, isDirectory: isDir.boolValue,
                                  size: size, modified: modified))
        }
        return sorted(list, sort)
    }

    static func sorted(_ list: [FileEntry], _ method: FileSortMethod) -> [FileEntry] {
        // 目录始终在前，与 Android 一致
        func dirFirst(_ a: FileEntry, _ b: FileEntry) -> Bool { a.isDirectory && !b.isDirectory }
        let primary: (FileEntry, FileEntry) -> Bool
        switch method {
        case .nameAsc: primary = { dirFirst($0, $1) || ($0.isDirectory == $1.isDirectory && $0.name.localizedCompare($1.name) == .orderedAscending) }
        case .nameDesc: primary = { dirFirst($0, $1) || ($0.isDirectory == $1.isDirectory && $0.name.localizedCompare($1.name) == .orderedDescending) }
        case .timeAsc: primary = { dirFirst($0, $1) || ($0.isDirectory == $1.isDirectory && $0.modified < $1.modified) }
        case .timeDesc: primary = { dirFirst($0, $1) || ($0.isDirectory == $1.isDirectory && $0.modified > $1.modified) }
        case .sizeAsc: primary = { dirFirst($0, $1) || ($0.isDirectory == $1.isDirectory && $0.size < $1.size) }
        case .sizeDesc: primary = { dirFirst($0, $1) || ($0.isDirectory == $1.isDirectory && $0.size > $1.size) }
        }
        return list.sorted(by: primary)
    }

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    @discardableResult
    static func delete(_ entry: FileEntry) -> Bool {
        do {
            try FileManager.default.removeItem(atPath: entry.path)
            return true
        } catch {
            LLog.error("delete \(entry.path) failed: \(error)")
            return false
        }
    }

    static func createDirectory(in dir: String, name: String) -> String? {
        let full = (dir as NSString).appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
            return full
        } catch {
            LLog.error("mkdir failed: \(error)")
            return nil
        }
    }

    /// 构造待发送的消息（按扩展名分类，目录生成 MessageFolderContent）
    static func message(for entry: FileEntry) -> MessageFileContent {
        if entry.isDirectory {
            let folder = MessageFolderContent()
            folder.name = entry.name
            folder.path = entry.path
            folder.length = entry.size
            return folder
        }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        if MediaKind.isImage(ext) {
            let media = MessageMediaContent(isVideo: false)
            media.name = entry.name
            media.path = entry.path
            media.length = entry.size
            media.isGif = ext == "gif"
            return media
        }
        if MediaKind.isVideo(ext) {
            let media = MessageMediaContent(isVideo: true, videoTime: MediaKind.durationText(of: entry.url))
            media.name = entry.name
            media.path = entry.path
            media.length = entry.size
            return media
        }
        if MediaKind.isAudio(ext) {
            let audio = MessageAudioContent()
            audio.name = entry.name
            audio.path = entry.path
            audio.length = entry.size
            audio.musicTime = MediaKind.durationText(of: entry.url)
            return audio
        }
        let file = MessageFileContent(name: entry.name, path: entry.path, length: entry.size)
        file.fileType = ext == "apk" ? MessageFileContent.fileTypeApk : MessageFileContent.fileTypeFile
        return file
    }

    static func messages(for entries: [FileEntry]) -> [MessageFileContent] {
        entries.map { message(for: $0) }
    }
}

// MARK: - 保存到相册 (Android: save_to_gallery)

enum MediaSaver {
    static func save(url: URL, isVideo: Bool) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                if isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }) { success, error in
                LLog.debug("save to gallery success=\(success) error=\(String(describing: error))")
            }
        }
    }
}

// MARK: - 媒体类型/时长

extension MessageFileContent {
    /// UI 侧总是有路径，取 URL 不需要可选处理
    var fileURLValue: URL { URL(fileURLWithPath: path) }
}

enum MediaKind {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "bmp", "webp", "tiff"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "3gp", "mkv", "flv", "rmvb", "wmv"]
    static let audioExtensions: Set<String> = ["mp3", "aac", "m4a", "wav", "flac", "ape", "ogg", "aiff"]

    static func isImage(_ ext: String) -> Bool { imageExtensions.contains(ext) }
    static func isVideo(_ ext: String) -> Bool { videoExtensions.contains(ext) }
    static func isAudio(_ ext: String) -> Bool { audioExtensions.contains(ext) }

    static func durationText(of url: URL) -> String {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite && seconds > 0 else { return "00:00" }
        return format(seconds: seconds)
    }

    static func format(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - 音频播放 (Android: MusicService + fragment_child_music.xml)

final class LMusicPlayer: ObservableObject {
    static let shared = LMusicPlayer()

    @Published var tracks: [FileEntry] = []
    @Published var index = -1
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    private init() {}

    var current: FileEntry? {
        tracks.indices.contains(index) ? tracks[index] : nil
    }

    func load(_ list: [FileEntry]) {
        tracks = list
        if index >= list.count { index = list.isEmpty ? -1 : 0 }
    }

    func play(url: URL) {
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            player = p
            duration = p.duration
            currentTime = 0
            p.play()
            isPlaying = true
            startTimer()
        } catch {
            LLog.error("audio play failed: \(error)")
            LANService.shared.showToast("无法播放该音频")
        }
    }

    func play(index target: Int) {
        guard tracks.indices.contains(target) else { return }
        index = target
        play(url: tracks[target].url)
    }

    func togglePlay() {
        guard let player else {
            if let first = tracks.first { index = 0; play(url: first.url) }
            return
        }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func next() {
        step(1)
    }

    func previous() {
        step(-1)
    }

    private func step(_ delta: Int) {
        guard !tracks.isEmpty else { return }
        let target = (index + delta + tracks.count) % tracks.count
        play(index: target)
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player?.currentTime = seconds
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        isPlaying = false
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            self.currentTime = player.currentTime
            self.duration = player.duration
            if !player.isPlaying && player.currentTime >= player.duration - 0.05 {
                self.step(1)
            }
        }
    }
}

// MARK: - QuickLook (Android: 打开文件)

struct QuickLookSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> QLPreviewController {
        let vc = QLPreviewController()
        vc.dataSource = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.urls = urls
        uiViewController.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(urls: urls) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var urls: [URL]
        init(urls: [URL]) { self.urls = urls }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { urls.count }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            urls[index] as NSURL
        }
    }
}

// MARK: - 视频播放 (Android: VideoPlayer)

struct VideoPlayerSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = AVPlayer(url: url)
        vc.showsPlaybackControls = true
        vc.player?.play()
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        uiViewController.player?.pause()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {}
}

// MARK: - 文本格式

enum LFormat {
    static let listDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    /// 聊天时间分隔 (Android: ChatAdapter 今天/昨天/完整日期)
    static func chatTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return timeOnly.string(from: date) }
        if calendar.isDateInYesterday(date) { return "昨天 " + timeOnly.string(from: date) }
        return listDate.string(from: date)
    }

    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
}
