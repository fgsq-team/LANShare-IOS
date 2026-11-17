import SwiftUI
import Photos
import AVFoundation

/// 媒体页 (Android: FragmentMediaList + fragment_child_photo.xml)
struct MediaBrowseView: View {
    @State private var status: PHAuthorizationStatus = .notDetermined
    @State private var albums: [MediaAlbum] = []
    @State private var selectedAlbums: Set<String> = []
    @State private var exporting = false
    @State private var exportDone = 0
    @State private var exportTotal = 0

    var body: some View {
        content
            .navigationDestination(for: MediaAlbum.self) { album in
                MediaAssetGrid(album: album)
            }
            .onAppear { request() }
            .overlay {
                if exporting {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("导出中 \(exportDone)/\(exportTotal)…").font(.footnote)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !selectedAlbums.isEmpty {
                    SendSelectionBar(label: "已选择 \(selectedAlbums.count) 个相册",
                                     onSend: { sendSelectedAlbums() },
                                     onClear: { selectedAlbums.removeAll() })
                        .disabled(exporting)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .denied, .restricted:
            ContentUnavailableView("没有相册权限", systemImage: "photo.badge.exclamationmark",
                                   description: Text("请在系统设置 → 隐私与安全性 → 照片中允许 LANShare 访问"))
        case .notDetermined:
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled").font(.largeTitle).foregroundStyle(.secondary)
                Text("LANShare 需要访问相册才能共享图片与视频").font(.footnote).foregroundStyle(.secondary)
                Button("允许访问相册") { request() }.buttonStyle(.borderedProminent)
            }
            .padding()
        default:
            if albums.isEmpty {
                ContentUnavailableView("没有可共享的媒体", systemImage: "photo",
                                       description: Text("相册中没有图片和视频"))
            } else {
                List {
                    Section {
                        ForEach(albums) { album in
                            albumRow(album)
                        }
                    } footer: {
                        HStack(spacing: 16) {
                            Button("全选") { selectedAlbums = Set(albums.map(\.id)) }
                            Button("取消全选") { selectedAlbums.removeAll() }
                        }
                        .font(.footnote)
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { load() }
            }
        }
    }

    /// 整相册多选：勾选框只记 id，点名称仍然进九宫格
    private func albumRow(_ album: MediaAlbum) -> some View {
        let checked = selectedAlbums.contains(album.id)
        // Android: photo_folder_item.xml — 50dp 封面 + 10dp 间距 + 15sp 名称 + 13sp 数量
        let rowContent = HStack(spacing: 10) {
            AlbumCover(asset: album.cover)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title).font(.system(size: 15))
                Text("\(album.count) 项")
                    .font(.system(size: 13))
                    .foregroundStyle(LColor.textSecondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        return HStack(spacing: 0) {
            // 隐藏的 NavigationLink 负责跳转，避免 List 自动加 › 箭头挡在勾选框前面
            ZStack {
                NavigationLink(value: album) { rowContent }
                    .opacity(0)
                rowContent.allowsHitTesting(false)
            }
            .opacity(checked ? 0.3 : 1)
            Button { toggle(album) } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(checked ? LColor.green : LColor.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func toggle(_ album: MediaAlbum) {
        if selectedAlbums.contains(album.id) {
            selectedAlbums.remove(album.id)
        } else {
            selectedAlbums.insert(album.id)
        }
    }

    /// 选中相册的全部媒体去重后导出，再选设备发送 (Android: 文件夹媒体同步按单文件下发，不打包目录)
    private func sendSelectedAlbums() {
        let assets = uniqueAssets(in: selectedAlbums)
        guard !assets.isEmpty else {
            LANService.shared.showToast("选中的相册里没有媒体")
            return
        }
        exporting = true
        exportDone = 0
        exportTotal = assets.count
        var out: [MessageFileContent] = []
        MediaExporter.shared.export(assets) { message, _ in
            DispatchQueue.main.async { self.exportDone += 1 }
            if let message { out.append(message) }
        } completion: {
            DispatchQueue.main.async {
                self.exporting = false
                guard !out.isEmpty else {
                    LANService.shared.showToast("媒体导出失败")
                    return
                }
                LAppModel.shared.pickDevice(title: "请选择需要接收的设备") { device in
                    LANService.shared.sendFiles(out, to: device)
                }
            }
        }
    }

    /// 智能相册之间大量重叠，同一资源只导一次
    private func uniqueAssets(in ids: Set<String>) -> [PHAsset] {
        var seen = Set<String>()
        var out: [PHAsset] = []
        for album in albums where ids.contains(album.id) {
            PHAsset.fetchAssets(in: album.collection, options: nil).enumerateObjects { asset, _, _ in
                guard seen.insert(asset.localIdentifier).inserted else { return }
                out.append(asset)
            }
        }
        return out
    }

    private func request() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { granted in
            DispatchQueue.main.async {
                status = granted
                if granted == .authorized || granted == .limited { load() }
            }
        }
    }

    private func load() {
        var list: [MediaAlbum] = []
        let entities: [(String, PHFetchResult<PHAssetCollection>)] = [
            ("系统相册", PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)),
            ("自建相册", PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)),
        ]
        for (section, result) in entities {
            result.enumerateObjects { collection, _, _ in
                let assets = PHAsset.fetchAssets(in: collection, options: nil)
                guard assets.count > 0, let title = collection.localizedTitle else { return }
                list.append(MediaAlbum(section: section, title: title, count: assets.count,
                                       cover: assets.lastObject, collection: collection))
            }
        }
        albums = list
        selectedAlbums.formIntersection(list.map(\.id))
    }
}

/// 相册封面 (Android: photo_folder_item_img 50dp centerCrop)
private struct AlbumCover: View {
    let asset: PHAsset?
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(.secondarySystemBackground))
            if let image {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                Image(systemName: "photo.on.rectangle").foregroundStyle(.secondary)
            }
        }
        .frame(width: 50, height: 50)
        .clipped()
        .cornerRadius(6)
        .task(id: asset?.localIdentifier) {
            guard let asset else { return }
            image = await MediaExporter.shared.thumbnail(for: asset, side: 50, scale: displayScale)
        }
    }
}

struct MediaAlbum: Identifiable, Hashable {
    let section: String
    let title: String
    let count: Int
    let cover: PHAsset?
    let collection: PHAssetCollection

    var id: String { collection.localIdentifier }

    static func == (lhs: MediaAlbum, rhs: MediaAlbum) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// 相册内的九宫格，支持选择模式 / 全选 / 发送 / 媒体同步
/// (Android: FragmentMediaList — GridLayoutManager(4)，点按预览、右上角勾选)
struct MediaAssetGrid: View {
    let album: MediaAlbum
    @StateObject private var selection = FilesSelection.shared
    @StateObject private var app = LAppModel.shared
    @State private var assets: [PHAsset] = []
    @State private var exporting = false

    /// 固定 4 列、1pt 间隔的满幅网格；自适应列数会让不同机型格宽忽大忽小
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 1), count: 4)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 1) {
                ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { position, asset in
                    MediaCell(asset: asset, checked: selection.containsMedia(asset.localIdentifier)) {
                        toggle(asset)
                    } onOpen: {
                        open(asset, at: position)
                    }
                    .contextMenu {
                        Button("发送") { sendNow([asset]) }
                        Button("媒体同步") { sync([asset]) }
                    }
                }
            }
        }
        .navigationTitle(album.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("全选") { assets.forEach { toggle($0, forceOn: true) } }
                    Button("取消全选") { assets.forEach { selection.removeMedia($0.localIdentifier) } }
                    Button("发送已选") { sendSelected() }
                    Button("同步已选") { sync(selectedAssets) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .overlay {
            if exporting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("导出中…").font(.footnote)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .transition(.opacity)
            }
        }
        // push 页面没有 FilesView 的底栏，选完直接在这里发，不必退回相册列表
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selection.isEmpty { SendSelectionBar() }
        }
        .task { reload() }
        .refreshable { reload() }
    }

    private func reload() {
        let result = PHAsset.fetchAssets(in: album.collection, options: nil)
        var list: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        assets = list
    }

    private var selectedAssets: [PHAsset] {
        assets.filter { selection.containsMedia($0.localIdentifier) }
    }

    private func open(_ asset: PHAsset, at position: Int) {
        if asset.mediaType == .image {
            app.previewAssets(assets, index: position)
        } else if let path = MediaExporter.shared.cached(for: asset)?.path, LFileStore.exists(path) {
            app.previewVideo(URL(fileURLWithPath: path))
        } else {
            exporting = true
            MediaExporter.shared.export([asset]) { message, _ in
                guard let message else { return }
                DispatchQueue.main.async { app.previewVideo(message.fileURLValue) }
            } completion: {
                DispatchQueue.main.async { self.exporting = false }
            }
        }
    }

    private func toggle(_ asset: PHAsset, forceOn: Bool = false) {
        if selection.containsMedia(asset.localIdentifier) && !forceOn {
            selection.removeMedia(asset.localIdentifier)
            return
        }
        if let cached = MediaExporter.shared.cached(for: asset) {
            selection.addMedia(cached, assetId: asset.localIdentifier)
        } else {
            export([asset])
        }
    }

    private func sendSelected() {
        let pending = selectedAssets.filter { MediaExporter.shared.cached(for: $0) == nil }
        guard pending.isEmpty else {
            export(pending) { FilesSelection.shared.send() }
            return
        }
        selection.send()
    }

    private func sync(_ targets: [PHAsset]) {
        guard !targets.isEmpty else { return }
        export(targets, thenSync: { paths, names in
            FilesSelection.shared.syncMedia(paths: paths, names: names)
        }, then: nil)
    }

    /// 直接发送指定资源（不进入已选列表）
    private func sendNow(_ targets: [PHAsset]) {
        guard !targets.isEmpty else { return }
        exporting = true
        var out: [MessageFileContent] = []
        MediaExporter.shared.export(targets) { message, _ in
            if let message { out.append(message) }
        } completion: {
            DispatchQueue.main.async {
                self.exporting = false
                guard !out.isEmpty else {
                    LANService.shared.showToast("媒体导出失败")
                    return
                }
                LAppModel.shared.pickDevice(title: "请选择需要接收的设备") { device in
                    LANService.shared.sendFiles(out, to: device)
                }
            }
        }
    }

    /// 导出到沙盒后才能进入 V4/V5 文件链
    private func export(_ targets: [PHAsset], then action: (() -> Void)? = nil) {
        export(targets, thenSync: nil, then: action)
    }

    private func export(_ targets: [PHAsset], thenSync: (([Int64: String], [Int64: String]) -> Void)?,
                        then action: (() -> Void)?) {
        guard !targets.isEmpty else { action?(); return }
        exporting = true
        var paths: [Int64: String] = [:]
        var names: [Int64: String] = [:]
        MediaExporter.shared.export(targets) { message, asset in
            guard let message else { return }
            let id = MediaIds.id(for: asset)
            paths[id] = message.path
            names[id] = message.name
            DispatchQueue.main.async {
                self.selection.addMedia(message, assetId: asset.localIdentifier)
            }
        } completion: {
            DispatchQueue.main.async {
                self.exporting = false
                if let thenSync { thenSync(paths, names) }
                action?()
            }
        }
    }
}

/// Android: photo_list_item.xml — 方格 + #111212 蒙版 + 右上 35dp 选择 + 右下 GIF 角标 + 底部 20dp 时长条
private struct MediaCell: View {
    let asset: PHAsset
    let checked: Bool
    let onCheck: () -> Void
    let onOpen: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(Color(.secondarySystemBackground))
                if let image {
                    // 先把图钉在格子里再裁剪，否则 scaledToFill 的溢出会把右上角徽标推到屏幕外
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            }
            .overlay(Color(.sRGB, red: 17/255, green: 18/255, blue: 18/255).opacity(checked ? 0.5 : 0.2))
            .overlay(alignment: .bottom) {
                if asset.mediaType == .video {
                    Text(MediaKind.format(seconds: asset.duration))
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 20)
                        .background(Color.black.opacity(0.5))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if asset.mediaType == .image && asset.playbackStyle == .imageAnimated {
                    Image("ic_gif")
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(height: 18)
                        .padding(3)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onCheck) {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .regular))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(checked ? .white : .white.opacity(0.85),
                                         checked ? accent : .black.opacity(0.35))
                        .shadow(color: .black.opacity(0.35), radius: 1)
                        .frame(width: 35, height: 35, alignment: .topTrailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            // 取图尺寸跟着格子走：旋转/分屏后重新按新的像素边长请求
            .task(id: "\(asset.localIdentifier)|\(Int(geo.size.width * displayScale))") {
                image = await MediaExporter.shared.thumbnail(for: asset,
                                                             side: geo.size.width,
                                                             scale: displayScale)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
    }

    private var accent: Color { LColor.primary }
}

// MARK: - 相册 → 沙盒文件

final class MediaExporter {
    static let shared = MediaExporter()

    private let manager = PHImageManager.default()
    private let cacheDir: String = {
        let base = (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory())
            as NSString
        let dir = base.appendingPathComponent("LANShareMedia")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()
    private var exported: [String: MessageFileContent] = [:]
    private let thumbCache = NSCache<NSString, UIImage>()
    private let gate = NSLock()
    private let callbackGate = NSLock()

    private init() {
        thumbCache.totalCostLimit = 64 * 1024 * 1024
        thumbCache.countLimit = 600
    }

    static func originalFilename(_ asset: PHAsset) -> String? {
        PHAssetResource.assetResources(for: asset).first?.originalFilename
    }

    func expectedPath(for asset: PHAsset) -> String {
        (cacheDir as NSString).appendingPathComponent(safeName(asset))
    }

    func cached(for asset: PHAsset) -> MessageFileContent? {
        gate.lock()
        defer { gate.unlock() }
        return exported[asset.localIdentifier]
    }

    func thumbnail(for asset: PHAsset, side: CGFloat, scale: CGFloat) async -> UIImage? {
        let px = max(64, Int((side * scale).rounded()))
        let key = "\(asset.localIdentifier)|\(px)" as NSString
        if let hit = thumbCache.object(forKey: key) { return hit }
        let image = await requestImage(asset, targetPx: px, contentMode: .aspectFill)
        if let image { thumbCache.setObject(image, forKey: key, cost: px * px / 256) }
        return image
    }

    /// 全屏预览取图：按显示像素请求 highQuality，避免整张原图解进内存
    func previewImage(for asset: PHAsset, maxPixel: CGFloat) async -> UIImage? {
        await requestImage(asset, targetPx: Int(maxPixel), contentMode: .aspectFit)
    }

    /// 单次回调的请求：highQualityFormat 保证只回调一次，不会重复 resume continuation
    private func requestImage(_ asset: PHAsset, targetPx: Int,
                              contentMode: PHImageContentMode) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            // 清晰度来自「请求尺寸 = 显示尺寸 × 屏幕倍率」，滤镜用 .fast 控制内存
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            manager.requestImage(for: asset,
                                 targetSize: CGSize(width: targetPx, height: targetPx),
                                 contentMode: contentMode,
                                 options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// 并发导出，逐个回调（回调串行，调用方可安全累加）；全部完成后调用 completion
    func export(_ assets: [PHAsset], each: @escaping (MessageFileContent?, PHAsset) -> Void,
                completion: @escaping () -> Void) {
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "fgsqw.media.export", qos: .utility, attributes: .concurrent)
        // 整个相册一起导时不能几百个请求同时压给 Photos，限流到 4 路
        let limit = DispatchSemaphore(value: 4)
        for asset in assets {
            if let cached = cached(for: asset), FileManager.default.fileExists(atPath: cached.path) {
                callbackGate.lock(); each(cached, asset); callbackGate.unlock()
                continue
            }
            group.enter()
            queue.async {
                limit.wait()
                let message = self.exportOne(asset)
                limit.signal()
                if let message {
                    self.gate.lock()
                    self.exported[asset.localIdentifier] = message
                    self.gate.unlock()
                }
                self.callbackGate.lock()
                each(message, asset)
                self.callbackGate.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { completion() }
    }

    private func exportOne(_ asset: PHAsset) -> MessageFileContent? {
        let path = expectedPath(for: asset)
        if FileManager.default.fileExists(atPath: path), let existing = rebuild(asset, path: path) {
            return existing
        }
        return asset.mediaType == .video ? exportVideo(asset, to: path) : exportImage(asset, to: path)
    }

    private func rebuild(_ asset: PHAsset, path: String) -> MessageFileContent? {
        let size = ResumeStore.fileSize(path)
        guard size > 0 else { return nil }
        if asset.mediaType == .video {
            let media = MessageMediaContent(isVideo: true, videoTime: MediaKind.format(seconds: asset.duration))
            media.name = (path as NSString).lastPathComponent
            media.path = path
            media.length = size
            media.mediaId = MediaIds.id(for: asset)
            media.assetIdentifier = asset.localIdentifier
            return media
        }
        let media = MessageMediaContent(isVideo: false)
        media.name = (path as NSString).lastPathComponent
        media.path = path
        media.length = size
        media.isGif = asset.playbackStyle == .imageAnimated
        media.mediaId = MediaIds.id(for: asset)
        media.assetIdentifier = asset.localIdentifier
        return media
    }

    private func safeName(_ asset: PHAsset) -> String {
        let raw = MediaExporter.originalFilename(asset) ?? "media"
        let ext = (raw as NSString).pathExtension.lowercased()
        let base = (raw as NSString).deletingPathExtension
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let suffix = String(asset.localIdentifier.prefix(8)).replacingOccurrences(of: "/", with: "_")
        let finalExt = ext.isEmpty ? (asset.mediaType == .video ? "mov" : "jpg") : ext
        return "\(base)_\(suffix).\(finalExt)"
    }

    private func exportImage(_ asset: PHAsset, to path: String) -> MessageFileContent? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.version = .current
        options.isNetworkAccessAllowed = true
        var data: Data?
        let sem = DispatchSemaphore(value: 0)
        manager.requestImageDataAndOrientation(for: asset, options: options) { result, _, _, _ in
            data = result
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 60) == .success, let data else { return nil }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return rebuild(asset, path: path)
        } catch {
            LLog.error("write image failed: \(error)")
            return nil
        }
    }

    private func exportVideo(_ asset: PHAsset, to path: String) -> MessageFileContent? {
        let options = PHVideoRequestOptions()
        options.version = .current
        options.isNetworkAccessAllowed = true
        var source: URL?
        var fallback: AVAsset?
        let sem = DispatchSemaphore(value: 0)
        manager.requestAVAsset(forVideo: asset, options: options) { result, _, _ in
            fallback = result
            if let urlAsset = result as? AVURLAsset, FileManager.default.fileExists(atPath: urlAsset.url.path) {
                source = urlAsset.url
            }
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 180) == .success else { return nil }
        if let source {
            try? FileManager.default.removeItem(atPath: path)
            do {
                try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: path))
                return rebuild(asset, path: path)
            } catch {
                LLog.error("copy video failed: \(error)")
            }
        }
        // 无原始文件（如剪辑过的视频）→ 用导出会话转码
        guard let fallback else { return nil }
        return transcode(fallback, to: path, asset: asset)
    }

    private func transcode(_ avAsset: AVAsset, to path: String, asset: PHAsset) -> MessageFileContent? {
        let preset: String
        if #available(iOS 16.0, *), AVAssetExportSession.exportPresets(compatibleWith: avAsset)
            .contains(AVAssetExportPresetHighestQuality) {
            preset = AVAssetExportPresetHighestQuality
        } else {
            preset = AVAssetExportPresetMediumQuality
        }
        guard let session = try? AVAssetExportSession(asset: avAsset, presetName: preset) else { return nil }
        let tmp = path + ".mov"
        try? FileManager.default.removeItem(atPath: tmp)
        session.outputURL = URL(fileURLWithPath: tmp)
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = true
        let sem = DispatchSemaphore(value: 0)
        session.exportAsynchronously { sem.signal() }
        guard sem.wait(timeout: .now() + 300) == .success, session.status == .completed else { return nil }
        try? FileManager.default.removeItem(atPath: path)
        do {
            try FileManager.default.moveItem(atPath: tmp, toPath: path)
            return rebuild(asset, path: path)
        } catch {
            LLog.error("move transcoded video failed: \(error)")
            return nil
        }
    }
}

/// PHAsset → 稳定的数值 mediaId（Android 侧使用 MediaStore 的 int id）
enum MediaIds {
    static func id(for asset: PHAsset) -> Int64 {
        var hash: UInt64 = 14695981039346656037
        for byte in asset.localIdentifier.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return Int64(truncatingIfNeeded: hash >> 1)
    }
}
