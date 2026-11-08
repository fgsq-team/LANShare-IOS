import SwiftUI
import Combine
import Photos

/// 跨页共享的发送选择 (Android: DataCenterActivity.addASandFile / FileSendDialog)
final class FilesSelection: ObservableObject {
    static let shared = FilesSelection()

    @Published var items: [MessageFileContent] = []
    @Published var reveal: String?

    private init() {}

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.length } }
    var totalSizeText: String { MessageFileContent.formatSize(totalSize) }

    func contains(_ path: String) -> Bool { items.contains { $0.path == path } }

    func set(_ message: MessageFileContent, checked: Bool) {
        items.removeAll { $0.path == message.path }
        if checked { items.append(message) }
    }

    func toggle(_ entry: FileEntry) {
        set(LFileStore.message(for: entry), checked: !contains(entry.path))
    }

    func selectAll(_ entries: [FileEntry]) {
        for entry in entries where !contains(entry.path) {
            items.append(LFileStore.message(for: entry))
        }
    }

    func clear() {
        items.removeAll()
    }

    /// 选择设备后发送 (Android: FileSendDialog → sendFiles)
    func send() {
        guard !items.isEmpty else { return }
        let files = items
        LAppModel.shared.pickDevice(title: "请选择需要接收的设备", showAllDevices: true) { device in
            LANService.shared.sendFiles(files, to: device)
            FilesSelection.shared.clear()
        }
    }

    /// 媒体同步：向对端请求其尚未拥有的媒体 (Android: FragmentMediaList 长按 → 媒体同步)
    func syncMedia(paths: [Int64: String], names: [Int64: String]) {
        let ids = Array(paths.keys)
        guard !ids.isEmpty else { return }
        LAppModel.shared.pickDevice(title: "请选择需要接收的设备", showAllDevices: false) { device in
            guard let device else { return }
            let service = LANService.shared
            service.fileSend.requestNoSyncMedia(to: device, mediaIds: ids) { missing in
                guard !missing.isEmpty else {
                    service.showToast("对方已拥有全部媒体")
                    return
                }
                var out: [MessageFileContent] = []
                for id in missing {
                    guard let path = paths[id], LFileStore.exists(path) else { continue }
                    let entry = FileEntry(name: names[id] ?? (path as NSString).lastPathComponent,
                                          path: path, isDirectory: false,
                                          size: ResumeStore.fileSize(path), modified: Date())
                    out.append(LFileStore.message(for: entry))
                }
                guard !out.isEmpty else {
                    service.showToast("没有可同步的媒体")
                    return
                }
                service.sendFiles(out, to: device)
            }
        }
    }

    // MARK: - 相册条目

    func containsMedia(_ assetId: String) -> Bool {
        items.contains { ($0 as? MessageMediaContent)?.assetIdentifier == assetId }
    }

    func addMedia(_ message: MessageFileContent, assetId: String) {
        items.removeAll { ($0 as? MessageMediaContent)?.assetIdentifier == assetId }
        items.append(message)
    }

    func removeMedia(_ assetId: String) {
        items.removeAll { ($0 as? MessageMediaContent)?.assetIdentifier == assetId }
    }
}

// MARK: - 文件页容器 (Android: FragmentFiles 的 TabLayout：应用/媒体/音频/文件/搜索)

struct FilesView: View {
    @StateObject private var selection = FilesSelection.shared
    @State private var tab: FileTab = .file

    enum FileTab: String, CaseIterable, Identifiable {
        case media = "媒体"
        case music = "音频"
        case file = "文件"
        case search = "搜索"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabCard
            switch tab {
            case .file: FileBrowserView()
            case .media: MediaBrowseView()
            case .music: MusicBrowseView()
            case .search: FileSearchView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selection.isEmpty { SendSelectionBar() }
        }
    }

    /// Android: fragment_files.xml 的 MaterialCardView(16dp/2dp 阴影) + 48dp TabLayout
    private var tabCard: some View {
        LCard(radius: 16, background: LColor.surfaceVariant, stroke: LColor.divider) {
            Picker("", selection: $tab) {
                ForEach(FileTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(LColor.primary)
            .padding(.horizontal, 4)
            .frame(height: 48)
        }
        .shadow(color: LColor.shadow.opacity(0.18), radius: 2, y: 1)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// 已选数量 + 发送栏。相册详情页是 push 出来的，拿不到 FilesView 的底栏，
/// 所以做成独立组件，各页共用 (Android: FileSendDialog 的选中数量 + 发送)。
/// 只报数量不铺缩略图：列表/九宫格里已经勾过了，再解码一遍缩略图只是卡顿。
/// 相册列表选的是整个相册而不是文件，用 label/onSend 覆盖默认的文件选择语义。
struct SendSelectionBar: View {
    @StateObject private var selection = FilesSelection.shared
    var label: String?
    var onSend: (() -> Void)?
    var onClear: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Button("清空") {
                if let onClear {
                    onClear()
                } else {
                    selection.clear()
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(label ?? "已选择 \(selection.count) 个").font(.footnote)
                if label == nil {
                    Text(selection.totalSizeText).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                if let onSend {
                    onSend()
                } else {
                    selection.send()
                }
            } label: {
                Text("发送")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(LColor.primary, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

// MARK: - 文件浏览 (Android: FragmentFileList + fragment_child_file.xml)

struct FileBrowserView: View {
    @StateObject private var selection = FilesSelection.shared
    @StateObject private var settings = LSettings.shared
    @State private var dir: String = LFileStore.root
    @State private var entries: [FileEntry] = []
    @State private var infoEntry: FileEntry?
    @State private var confirmDelete: FileEntry?
    @State private var newFolderName = ""
    @State private var showNewFolder = false

    var body: some View {
        List {
            Section {
                if LFileStore.parent(of: dir) != nil || dir != LFileStore.root {
                    Button {
                        dir = LFileStore.parent(of: dir) ?? LFileStore.root
                        reload()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.up.doc")
                                .font(.system(size: 24))
                                .foregroundStyle(LColor.icon)
                                .frame(width: 40, height: 40)
                            Text("..")
                                .font(.system(size: 15))
                                .foregroundStyle(LColor.textPrimary)
                            Spacer(minLength: 44)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(entries) { entry in
                    FileRow(entry: entry, checked: selection.contains(entry.path)) {
                        selection.toggle(entry)
                    } onTap: {
                        handle(entry)
                    } onInfo: {
                        infoEntry = entry
                    } onDelete: {
                        confirmDelete = entry
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    Text(pathLabel)
                    Spacer()
                    Menu {
                        Button("新建文件夹") { showNewFolder = true }
                        Button(settings.showHiddenFiles ? "隐藏隐藏文件" : "显示隐藏文件") {
                            settings.showHiddenFiles.toggle()
                        }
                        Picker("排序方式", selection: $settings.fileSortMethod) {
                            ForEach(FileSortMethod.allCases) { Text($0.label).tag($0) }
                        }
                        Button("刷新") { reload() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(LColor.primary)
                    }
                    Text(entries.isEmpty ? "空" : "\(entries.count) 项").foregroundStyle(.secondary)
                }
                .font(.footnote)
            } footer: {
                Button("全选") { selection.selectAll(entries) }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { reload() }
        .onAppear { reload() }
        .onChange(of: settings.showHiddenFiles) { _, _ in reload() }
        .onChange(of: settings.fileSortMethod) { _, _ in reload() }
        .onChange(of: selection.reveal) { _, path in
            guard let path else { return }
            dir = LFileStore.parent(of: path) ?? LFileStore.root
            reload()
            selection.reveal = nil
        }
        .sheet(item: $infoEntry) { entry in
            FileInfoSheet(entry: entry)
        }
        .confirmationDialog("删除文件不可恢复，是否继续选中文件?", isPresented: deleteBinding, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let entry = confirmDelete {
                    LANService.shared.showToast(LFileStore.delete(entry) ? "已删除 " + entry.name : "删除失败")
                    reload()
                }
                confirmDelete = nil
            }
            Button("取消", role: .cancel) { confirmDelete = nil }
        }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("名称", text: $newFolderName)
            Button("确定") {
                if !newFolderName.isEmpty, LFileStore.createDirectory(in: dir, name: newFolderName) != nil {
                    reload()
                }
                newFolderName = ""
            }
            Button("取消", role: .cancel) { newFolderName = "" }
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
    }

    private var pathLabel: String {
        dir == LFileStore.root ? "我的文件" : (dir as NSString).lastPathComponent
    }

    private func reload() {
        entries = LFileStore.entries(in: dir, showHidden: settings.showHiddenFiles, sort: settings.fileSortMethod)
    }

    private func handle(_ entry: FileEntry) {
        if entry.isDirectory {
            dir = entry.path
            reload()
            return
        }
        MediaOp.open(entry, in: entries)
    }
}

/// Android: file_list_item.xml (40dp 图标 + 15sp 名称 + 12sp 信息 + 44dp 选择区)
struct FileRow<Trailing: View>: View {
    let entry: FileEntry
    let checked: Bool
    let onCheck: () -> Void
    let onTap: () -> Void
    let onInfo: () -> Void
    let onDelete: () -> Void
    var subtitleOverride: String?
    var nameTint: Color?
    var trailing: () -> Trailing

    init(entry: FileEntry,
         checked: Bool,
         onCheck: @escaping () -> Void,
         onTap: @escaping () -> Void,
         onInfo: @escaping () -> Void = {},
         onDelete: @escaping () -> Void = {},
         subtitle: String? = nil,
         nameTint: Color? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.entry = entry
        self.checked = checked
        self.onCheck = onCheck
        self.onTap = onTap
        self.onInfo = onInfo
        self.onDelete = onDelete
        self.subtitleOverride = subtitle
        self.nameTint = nameTint
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                icon
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name)
                        .font(.system(size: 15))
                        .foregroundStyle(nameTint ?? LColor.textPrimary)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(LColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                trailing()
            }
            .opacity(checked ? 0.3 : 1)
            Button(action: onCheck) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(checked ? LColor.green : LColor.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button("发送") { if !checked { onCheck() } }
            Button("打开") { onTap() }
            if !entry.isDirectory {
                Button("信息") { onInfo() }
            }
            Button("删除", role: .destructive) { onDelete() }
        }
    }

    @ViewBuilder private var icon: some View {
        if entry.isDirectory {
            Image(systemName: "folder.fill")
                .font(.system(size: 26))
                .foregroundStyle(LColor.primary)
        } else if entry.category == "图片" || entry.category == "视频" {
            ThumbnailView(url: entry.url, isVideo: entry.category == "视频", side: 80)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: entry.systemIcon)
                .font(.system(size: 24))
                .foregroundStyle(LColor.icon)
        }
    }

    private var subtitle: String {
        if let subtitleOverride { return subtitleOverride }
        let date = LFormat.listDate.string(from: entry.modified)
        return entry.isDirectory ? "\(date) 0 B" : "\(date) \(entry.sizeText)"
    }
}

/// 文件信息 (Android: FileInfoDialog)
struct FileInfoSheet: View {
    let entry: FileEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // Android: dialog_file_info.xml 的 文件名/路径/大小/修改时间 四行，值可选中复制
                LabeledContent("文件名：", value: entry.name)
                LabeledContent("路径：", value: entry.path)
                LabeledContent("大小：", value: entry.isDirectory ? "文件夹" : entry.sizeText)
                LabeledContent("修改时间：", value: LFormat.fullDate.string(from: entry.modified))
                LabeledContent("分类：", value: entry.category)
            }
            .textSelection(.enabled)
            .navigationTitle("提示")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// 按类型打开条目：图片/视频/音频走内置播放器，其余走 QuickLook
/// (Android: open_media_on_internal_player)
enum MediaOp {
    static func open(_ entry: FileEntry, in list: [FileEntry]) {
        let app = LAppModel.shared
        let ext = (entry.name as NSString).pathExtension.lowercased()
        guard LSettings.shared.openMediaOnInternalPlayer else {
            app.preview(entry.url)
            return
        }
        if MediaKind.isImage(ext) {
            let paths = list.filter { MediaKind.isImage(($0.name as NSString).pathExtension.lowercased()) }.map(\.path)
            app.previewImages(paths: paths.isEmpty ? [entry.path] : paths,
                              index: paths.firstIndex(of: entry.path) ?? 0)
        } else if MediaKind.isVideo(ext) {
            app.previewVideo(entry.url)
        } else if MediaKind.isAudio(ext) {
            let tracks = list.filter { MediaKind.isAudio(($0.name as NSString).pathExtension.lowercased()) }
            LMusicPlayer.shared.load(tracks)
            if let idx = tracks.firstIndex(of: entry) { LMusicPlayer.shared.play(index: idx) }
        } else {
            app.preview(entry.url)
        }
    }
}
