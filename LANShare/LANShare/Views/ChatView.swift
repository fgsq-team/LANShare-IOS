import SwiftUI
import Combine
import AVFoundation
import UIKit
import CoreLocation

/// 聊天多选删除状态；删除栏在 RootView 底部（Android: DataCenterActivity.setDeleteMode）
final class ChatSelection: ObservableObject {
    static let shared = ChatSelection()

    @Published var deleteMode = false
    @Published var selected: Set<String> = []
    /// 输入框草稿，扫码到的普通文本会回填到这里 (Android: fragmentChat.setEditContent)
    @Published var draft = ""

    private init() {}

    func enter(_ id: String) {
        deleteMode = true
        selected = [id]
    }

    func exit() {
        deleteMode = false
        selected.removeAll()
    }

    func toggle(_ id: String) {
        if deleteMode {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        } else {
            enter(id)
        }
    }

    func isAllSelected(_ messages: [MessageContent]) -> Bool {
        !messages.isEmpty && selected.count == messages.count
    }

    func toggleAll(_ messages: [MessageContent]) {
        selected = isAllSelected(messages) ? [] : Set(messages.map { $0.id })
    }

    func delete(_ messages: [MessageContent]) {
        guard !selected.isEmpty else { return }
        LANService.shared.deleteMessages(messages.filter { selected.contains($0.id) })
        exit()
    }
}

/// 聊天页 (Android: FragmentChat + fragment_chat.xml)
struct ChatView: View {
    @StateObject private var service = LANService.shared
    @StateObject private var settings = LSettings.shared
    @StateObject private var app = LAppModel.shared
    @StateObject private var selection = ChatSelection.shared
    /// 换 id 让顶部哨兵重新可见时再次触发 onAppear，从而连续翻页
    @State private var olderSentinelArm = 0
    /// 只有首屏定位到底、且上一次翻页的滚动落定之后，哨兵才允许翻页
    @State private var paginationArmed = false

    var body: some View {
        VStack(spacing: 0) {
            messageList
            // Android: setChatEditVisibility(false) —— 多选时隐藏输入区
            if !selection.deleteMode { inputBar }
        }
        .background(LColor.chatBackground)
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    olderIndicator(proxy: proxy)
                    ForEach(service.messages) { message in
                        MessageRowView(message: message)
                            .id(message.id)
                            .contextMenu { rowMenu(message) }
                            .overlay {
                                if selection.deleteMode {
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .onTapGesture { selection.toggle(message.id) }
                                }
                            }
                    }
                }
                .padding(.vertical, 8)
            }
            // 首屏直接锚在底部，既不用手动 scrollTo，顶部哨兵也不会被顺手露一次面
            .defaultScrollAnchor(.bottom)
            .onAppear {
                paginationArmed = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    paginationArmed = true
                }
            }
            .onDisappear { paginationArmed = false }
            // 只有队尾变化才回到底部，向上翻页时保持原位置
            .onChange(of: service.messages.last?.id) { _, last in
                guard let last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func olderIndicator(proxy: ScrollViewProxy) -> some View {
        if service.hasOlderMessages {
            Color.clear
                .frame(height: 1)
                .id("older-sentinel-\(olderSentinelArm)")
                .onAppear {
                    guard paginationArmed else { return }
                    loadOlder(proxy: proxy)
                }
            if service.isLoadingOlderMessages {
                ProgressView().controlSize(.mini).padding(.vertical, 6)
            }
        }
    }

    private func loadOlder(proxy: ScrollViewProxy) {
        guard !service.isLoadingOlderMessages else { return }
        // 翻页期间先关门：换 id 后哨兵会立刻再 onAppear 一次，不停手就会连着往上加载
        paginationArmed = false
        let anchor = service.messages.first?.id
        service.loadOlderMessages { inserted in
            olderSentinelArm += 1
            guard inserted, let anchor else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { paginationArmed = true }
                return
            }
            // 让翻页前的首条仍停在顶部 (Android: scrollToPositionWithOffset(size, 0))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                proxy.scrollTo(anchor, anchor: .top)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { paginationArmed = true }
            }
        }
    }

    // MARK: - 长按菜单 (Android: recy_menu.xml)

    @ViewBuilder
    private func rowMenu(_ message: MessageContent) -> some View {
        if let file = message as? MessageFileContent, !file.isFinal, file.isLeft {
            Button("取消传输") { file.cancelTransfer() }
        }
        if message is MessageTextContent {
            Button("复制文本") { app.copyToPasteboard(message.content) }
        }
        if let file = message as? MessageFileContent, LFileStore.exists(file.path) {
            Button("打开文件") { app.preview(file.fileURLValue) }
            Button("在文件列表中定位") { FilesSelection.shared.reveal = file.path }
        }
        Button(selection.deleteMode ? "移出已选" : "多选删除", role: .destructive) {
            selection.toggle(message.id)
        }
    }

    // MARK: - 输入栏 (Android: fragment_chat.xml 的 chat_edit_layout)

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                deviceChip
                Spacer()
                Button {
                    sendLocation()
                } label: {
                    Label("发送位置", systemImage: "location.circle")
                        .font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(LColor.primary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("发送消息", text: $selection.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(LColor.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: 40)
                    .background(LColor.surfaceVariant, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(LColor.divider, lineWidth: 1))
                sendButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(LColor.surface)
    }

    /// 圆形发送按钮 (Android: btn_send_circle_background + ic_send_white)
    private var sendButton: some View {
        SendCircleButton(isEmpty: selection.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            send()
        }
        .contextMenu {
            Button("发送至设备剪切板") { send(isClip: true) }
        }
        .accessibilityLabel("发送")
    }

    /// 设备选择 (Android: chat_dev_select_tv + chip_background)
    private var deviceChip: some View {
        Button {
            app.pickDevice { device in
                app.chatTarget = device
            }
        } label: {
            Text(app.chatTarget?.devName ?? LConst.allDevicesKey)
                .font(.system(size: 13))
                .foregroundStyle(LColor.primary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(LColor.primaryLight, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("所有设备") { app.chatTarget = nil }
            ForEach(service.devices) { device in
                Button(device.devName) { app.chatTarget = device }
            }
        }
    }

    private func send(isClip: Bool = false) {
        let text = selection.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        selection.draft = ""
        service.sendTextMessage(text, to: app.chatTarget, isClip: isClip)
    }

    /// 发送位置 (Android: udpSendMap)
    private func sendLocation() {
        LLocationShare.shared.current { latitude, longitude, address in
            let gps = MessageGPSContent()
            gps.latitude = latitude
            gps.longitude = longitude
            gps.address = address
            gps.placeName = address
            gps.content = address
            service.sendGPS(gps, to: app.chatTarget)
        }
    }
}

/// 40dp 圆形发送键，按下变深、禁用变灰 (Android: btn_send_circle_background 的四态)
private struct SendCircleButton: View {
    let isEmpty: Bool
    let action: () -> Void
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(fillColor))
        }
        .buttonStyle(LPressButtonStyle(pressed: $pressed))
    }

    private var fillColor: Color {
        if isEmpty { return LColor.divider }
        return pressed ? LColor.primaryDark : LColor.primary
    }
}

/// 单次定位 (Android: 高德/腾讯定位；iOS 用系统定位)
final class LLocationShare: NSObject, CLLocationManagerDelegate {
    static let shared = LLocationShare()

    private let manager = CLLocationManager()
    private var pending: ((String, String, String) -> Void)?
    private let geocoder = CLGeocoder()

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func current(_ completion: @escaping (String, String, String) -> Void) {
        pending = completion
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            pending = nil
            LANService.shared.showToast("没有定位权限")
        default:
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let latitude = String(format: "%.6f", location.coordinate.latitude)
        let longitude = String(format: "%.6f", location.coordinate.longitude)
        resolveAddress(latitude: latitude, longitude: longitude, coordinate: location.coordinate)
    }

    private func resolveAddress(latitude: String, longitude: String, coordinate: CLLocationCoordinate2D) {
        let completion = pending
        pending = nil
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        geocoder.reverseGeocodeLocation(location) { marks, _ in
            let mark = marks?.first
            let name = [mark?.name, mark?.subLocality, mark?.locality]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            DispatchQueue.main.async {
                completion?(latitude, longitude, name.isEmpty ? "\(latitude),\(longitude)" : name)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        pending = nil
        LANService.shared.showToast("定位失败：\(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.requestLocation()
        }
    }
}

/// 单条消息 (Android: ChatAdapter 的多种 itemViewType)
struct MessageRowView: View {
    @ObservedObject var message: MessageContent
    @ObservedObject private var selection = ChatSelection.shared

    var body: some View {
        if message is MessageTimeContent || message is MessageGPSContent {
            centeredLine
        } else {
            row
        }
    }

    /// 时间分隔与位置消息都是居中细字 (Android: chat_time_item / chat_left_gps_item)
    private var centeredLine: some View {
        Group {
            if let time = message as? MessageTimeContent {
                Text(LFormat.chatTime(time.createTime))
            } else {
                Text(message.content)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(message is MessageTimeContent ? LColor.itemText : LColor.chatInfoText)
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .onTapGesture {
            guard !(message is MessageTimeContent), !selection.deleteMode else { return }
            guard let gps = message as? MessageGPSContent else { return }
            LAppModel.shared.copyToPasteboard("\(gps.latitude),\(gps.longitude)")
        }
    }

    private var row: some View {
        let left = message.isLeft
        return HStack(alignment: .top, spacing: 0) {
            if selection.deleteMode {
                Image(systemName: selection.selected.contains(message.id)
                      ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(selection.selected.contains(message.id)
                                     ? LColor.primary : LColor.textTertiary)
                    .padding(.trailing, 8)
                    .padding(.top, 6)
            }
            if left {
                avatar
                column
                Spacer(minLength: 16)
            } else {
                Spacer(minLength: 16)
                column
                avatar
            }
        }
        .padding(.leading, left ? 12 : 16)
        .padding(.trailing, left ? 16 : 12)
        .padding(.vertical, 6)
        .background(LColor.chatBackground)
    }

    /// 头像：Windows 设备用电脑图标，其余用手机图标 (Android: ic_pc / ic_phone)
    private var avatar: some View {
        Image(DevMode(rawValue: message.devMode) == .windows ? "ic_pc" : "ic_phone")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 40, height: 40)
            .foregroundStyle(LColor.icon)
    }

    private var column: some View {
        VStack(alignment: message.isLeft ? .leading : .trailing, spacing: 4) {
            if !nameText.isEmpty {
                Text(nameText)
                    .font(.system(size: 12))
                    .foregroundStyle(LColor.textSecondary)
                    .lineLimit(1)
            }
            bubble
        }
        .padding(.horizontal, 10)
    }

    /// Android: 左显示对端名，右显示 “目标 ← 本机”
    private var nameText: String {
        if message.isLeft { return message.userName }
        let to = message.toUser.isEmpty ? LConst.allDevicesKey : message.toUser
        return "\(to) ← \(message.userName)"
    }

    @ViewBuilder
    private var bubble: some View {
        if let media = message as? MessageMediaContent {
            MediaBubble(media: media)
        } else if let file = message as? MessageFileContent {
            FileBubble(file: file)
        } else if let text = message as? MessageTextContent {
            TextBubble(text: text)
        } else {
            TextBubble(text: MessageTextContent())
        }
    }
}

extension View {
    /// Android: chat_left_bg / chat_right_bg 的四角不对称圆角
    func chatBubble(isLeft: Bool) -> some View {
        background(
            BubbleShape(topLeft: isLeft ? 4 : 18,
                        topRight: isLeft ? 18 : 4,
                        bottomLeft: 18,
                        bottomRight: 18)
                .fill(isLeft ? LColor.chatLeftBackground : LColor.chatRightBackground)
        )
    }
}

/// 文本气泡 (Android: chat_left_item / chat_right_item)
private struct TextBubble: View {
    @ObservedObject var text: MessageTextContent

    var body: some View {
        HStack(spacing: 4) {
            if text.isClip {
                Image(systemName: "doc.on.clipboard").font(.system(size: 11))
            }
            Text(text.content)
                .font(.system(size: 15))
                .lineSpacing(2)
        }
        .foregroundStyle(text.isLeft ? LColor.chatLeftText : LColor.chatRightText)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .chatBubble(isLeft: text.isLeft)
        .frame(maxWidth: 260, alignment: text.isLeft ? .leading : .trailing)
    }
}

/// 文件气泡 (Android: chat_left_file_item.xml)
private struct FileBubble: View {
    @ObservedObject var file: MessageFileContent
    @StateObject private var app = LAppModel.shared

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            FileIconTile(symbol: rowIcon)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name.isEmpty ? LConst.folderLabel : file.name)
                    .font(.system(size: 16))
                    .foregroundStyle(file.isLeft ? LColor.chatLeftText : LColor.chatRightText)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(file.isLeft ? LColor.chatLeftInfoText : LColor.chatRightInfoText)
                status
            }
        }
        .padding(10)
        .chatBubble(isLeft: file.isLeft)
        .onTapGesture { open() }
    }

    @ViewBuilder
    private var status: some View {
        if file.isFinal || !file.isTransfer {
            StatusBadge(text: stateText, kind: badgeKind, isLeft: file.isLeft)
        } else {
            ProgressCapsule(progress: file.progress, isLeft: file.isLeft)
                .frame(width: 100, height: 8)
        }
    }

    private var stateText: String {
        if !file.isTransfer && !file.isFinal { return "已取消" }
        if file.isError && file.stateMessage.isEmpty { return "失败" }
        return file.stateMessage
    }

    private var badgeKind: StatusBadge.Kind {
        if file.isSuccess { return .success }
        if file.isError { return .error }
        return .neutral
    }

    private var subtitle: String {
        if file.isFolder { return file.sizeText }
        let size = MessageFileContent.formatSize(file.length)
        if let audio = file as? MessageAudioContent, !audio.musicTime.isEmpty {
            return "\(size) · \(audio.musicTime)"
        }
        return size
    }

    private var rowIcon: String {
        if file.isFolder { return "folder.fill" }
        if file is MessageAudioContent { return "music.note" }
        switch file.fileType {
        case MessageFileContent.fileTypeImage: return "photo"
        case MessageFileContent.fileTypeVideo: return "movie"
        case MessageFileContent.fileTypeApk: return "shippingbox"
        default: return "doc.fill"
        }
    }

    private func open() {
        guard LFileStore.exists(file.path) else {
            LANService.shared.showToast("文件不存在")
            return
        }
        if file.isFolder {
            FilesSelection.shared.reveal = file.path
            return
        }
        let ext = (file.name as NSString).pathExtension.lowercased()
        if MediaKind.isImage(ext) {
            app.previewImages(paths: [file.path])
        } else if MediaKind.isVideo(ext) {
            app.previewVideo(file.fileURLValue)
        } else if let audio = file as? MessageAudioContent, let dir = LFileStore.parent(of: audio.path) {
            LMusicPlayer.shared.load(LFileStore.entries(in: dir, showHidden: false, sort: .nameAsc)
                .filter { MediaKind.isAudio(($0.name as NSString).pathExtension.lowercased()) })
            if let idx = LMusicPlayer.shared.tracks.firstIndex(where: { $0.path == audio.path }) {
                LMusicPlayer.shared.play(index: idx)
            }
        } else {
            app.preview(file.fileURLValue)
        }
    }
}

/// 图片/视频气泡 (Android: chat_left_media_item.xml，160x110 缩略图 + 底部进度 + 左上时长)
private struct MediaBubble: View {
    @ObservedObject var media: MessageMediaContent
    @StateObject private var app = LAppModel.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(LColor.surfaceVariant)
            if LFileStore.exists(media.path) {
                ThumbnailView(url: media.fileURLValue, isVideo: media.isVideo)
            }
            if !media.isSuccess {
                VStack(spacing: 2) {
                    if !media.isFinal || !media.isSuccess {
                        Text(MessageFileContent.formatSize(media.length))
                            .font(.system(size: 12))
                            .foregroundStyle(LColor.mediaText)
                        Text(media.name)
                            .font(.system(size: 13))
                            .foregroundStyle(LColor.mediaText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 5)
                    }
                    if !media.isFinal {
                        ProgressCapsule(progress: media.progress, isLeft: media.isLeft)
                            .frame(width: 140, height: 6)
                            .padding(.bottom, 4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if media.isVideo {
                Text(media.videoTime)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                    .padding(5)
            }
        }
        .frame(width: 160, height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LColor.divider, lineWidth: 1))
        .onTapGesture { open() }
    }

    private func open() {
        guard LFileStore.exists(media.path) else {
            LANService.shared.showToast("文件不存在")
            return
        }
        if media.isVideo {
            app.previewVideo(media.fileURLValue)
        } else {
            app.previewImages(paths: [media.path])
        }
    }
}

/// 50dp 圆角瓦片 + 主题色文件符号 (Android: rc_file_icon_file / rc_file_blue_icon)
private struct FileIconTile: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 22))
            .foregroundStyle(LColor.primary)
            .frame(width: 50, height: 50)
            .background(LColor.fileIconBackground, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 胶囊进度条 (Android: progress_capsule_left / progress_capsule_right)
private struct ProgressCapsule: View {
    let progress: Int
    let isLeft: Bool

    var body: some View {
        GeometryReader { geo in
            let ratio = CGFloat(max(min(progress, 100), 0)) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(isLeft ? Color.black.opacity(0.2) : Color.black.opacity(0.3))
                Capsule()
                    .fill(isLeft ? Color(red: 0.30, green: 0.68, blue: 0.31) : Color.white)
                    .frame(width: geo.size.width * ratio)
            }
        }
    }
}

/// 终态徽章 (Android: chat_rc_msg_canceled + chat_status_badge_*)
private struct StatusBadge: View {
    enum Kind {
        case success, error, neutral

        var icon: String? {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .error: return "exclamationmark.triangle.fill"
            case .neutral: return nil
            }
        }
    }

    let text: String
    let kind: Kind
    let isLeft: Bool

    var body: some View {
        if text.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 3) {
                if let icon = kind.icon {
                    Image(systemName: icon).font(.system(size: 10))
                }
                Text(text).font(.system(size: 11))
            }
            .foregroundStyle(tint)
            .padding(.leading, 7)
            .padding(.trailing, 9)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 11)
                .fill(isLeft ? Color(red: 0.30, green: 0.68, blue: 0.31).opacity(0.13)
                             : Color.black.opacity(0.25)))
        }
    }

    private var tint: Color {
        switch kind {
        case .success: return isLeft ? LColor.chatLeftSuccess : .white
        case .error: return isLeft ? LColor.error : .white
        case .neutral: return isLeft ? LColor.chatLeftInfoText : LColor.chatRightInfoText
        }
    }
}
/// 缩略图 (Android: Glide 加载 + RoundImageView centerCrop)
struct ThumbnailView: View {
    let url: URL
    let isVideo: Bool
    /// 显示区长边（点），据此决定解码像素，避免整图解码或过小放大
    var side: CGFloat = 160
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Rectangle().fill(Color(.tertiarySystemBackground))
                    .overlay(Image(systemName: isVideo ? "play.rectangle" : "photo").foregroundStyle(.secondary))
            }
        }
        .clipped()
        .task(id: url) {
            image = await ThumbnailCache.shared.image(for: url, isVideo: isVideo,
                                                      maxPixel: side * displayScale)
        }
    }
}

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {}

    func image(for url: URL, isVideo: Bool, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(url.path)|\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image: UIImage?
        if isVideo {
            image = await Task.detached(priority: .userInitiated) { Self.videoFrame(url, maxPixel: maxPixel) }.value
        } else {
            image = await LImageLoader.load(path: url.path, maxPixel: maxPixel)
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private static func videoFrame(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel * 1.5, height: maxPixel * 1.5)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }
}
