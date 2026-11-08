import SwiftUI

// MARK: - 音频页 (Android: FragmentMusic + fragment_child_music.xml)

struct MusicBrowseView: View {
    @StateObject private var player = LMusicPlayer.shared
    @StateObject private var selection = FilesSelection.shared
    @State private var tracks: [FileEntry] = []
    @State private var seekValue: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(tracks) { entry in
                        row(entry)
                    }
                } header: {
                    HStack {
                        Text("音频")
                        Spacer()
                        Text(tracks.isEmpty ? "沙盒中没有音频文件" : "\(tracks.count) 首")
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                }
            }
            .listStyle(.insetGrouped)
            playerBar
        }
        .onAppear(perform: reload)
        .refreshable { reload() }
    }

    private func row(_ entry: FileEntry) -> some View {
        let index = tracks.firstIndex(of: entry) ?? 0
        let active = player.index == index
        return FileRow(
            entry: entry,
            checked: selection.contains(entry.path),
            onCheck: { selection.toggle(entry) },
            onTap: { player.play(index: index) },
            onInfo: { LAppModel.shared.copyToPasteboard(entry.path) },
            subtitle: "\(LFormat.listDate.string(from: entry.modified)) \(entry.sizeText)",
            nameTint: active ? LColor.primary : nil
        ) {
            Button {
                player.play(index: index)
            } label: {
                Image(systemName: active && player.isPlaying ? "speaker.wave.2.fill" : "play.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(LColor.primary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .contextMenu {
            Button(player.isPlaying && active ? "暂停" : "播放") { player.togglePlay() }
            Button("发送") { if !selection.contains(entry.path) { selection.toggle(entry) } }
            Button("信息") { LAppModel.shared.copyToPasteboard(entry.path) }
        }
    }

    @ObservedObject private var settings = LSettings.shared

    private var playerBar: some View {
        VStack(spacing: 4) {
            if let current = player.current {
                HStack(spacing: 10) {
                    Button { player.previous() } label: { Image(systemName: "backward.fill") }
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title)
                    }
                    Button { player.next() } label: { Image(systemName: "forward.fill") }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.name).font(.footnote).lineLimit(1)
                        Slider(value: Binding(get: { player.duration > 0 ? player.currentTime / player.duration : 0 },
                                             set: { player.seek(to: $0 * player.duration) }),
                               in: 0...1)
                    }
                    Text("\(LFormatClock.time(player.currentTime)) / \(LFormatClock.time(player.duration))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func reload() {
        tracks = LFileSearch.audioFiles()
        player.load(tracks)
    }
}

enum LFormatClock {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        return MediaKind.format(seconds: seconds)
    }
}

// MARK: - 搜索页 (Android: FragmentSearch + fragment_child_search.xml)

struct FileSearchView: View {
    @StateObject private var selection = FilesSelection.shared
    @State private var keyword = ""
    @State private var results: [FileEntry] = []
    @State private var searched = false
    @State private var searching = false

    /// 与 settings.searchFlags 对应：图片 / 视频 / 音频 / 其他
    @State private var flags = LSettings.shared.searchFlags

    var body: some View {
        VStack(spacing: 0) {
            // Android: fragment_child_search.xml 的 60dp 搜索行
            HStack(spacing: 10) {
                TextField("请输入搜索内容", text: $keyword)
                    .font(.system(size: 16))
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .background(LColor.chatLeftBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(LColor.divider, lineWidth: 1))
                    .onSubmit { search() }
                Button { search() } label: {
                    Text("搜索")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .frame(minWidth: 60, minHeight: 35)
                        .background(LColor.primary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(10)

            filterBar

            List {
                Section {
                    ForEach(results) { entry in
                        row(entry)
                    }
                } header: {
                    Text(searched ? "\(results.count) 个结果" : "输入关键字后搜索本机文件")
                        .font(.footnote)
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if searching { ProgressView() }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            filterChip("图片", index: 0)
            filterChip("视频", index: 1)
            filterChip("音频", index: 2)
            filterChip("其他", index: 3)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func filterChip(_ title: String, index: Int) -> some View {
        let on = flags.indices.contains(index) ? flags[index] : true
        return Button {
            guard flags.indices.contains(index) else { return }
            flags[index].toggle()
            LSettings.shared.searchFlags = flags
            search()
        } label: {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(on ? LColor.primary.opacity(0.2) : Color(.secondarySystemBackground),
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func row(_ entry: FileEntry) -> some View {
        FileRow(
            entry: entry,
            checked: selection.contains(entry.path),
            onCheck: { selection.toggle(entry) },
            onTap: { MediaOp.open(entry, in: results) },
            subtitle: entry.path.replacingOccurrences(of: LFileStore.root, with: "~")
        )
    }

    private func search() {
        let text = keyword.trimmingCharacters(in: .whitespaces)
        searched = true
        guard !text.isEmpty else {
            results = []
            return
        }
        searching = true
        LThread.run {
            let found = LFileSearch.search(text, flags: flags)
            DispatchQueue.main.async {
                results = found
                searching = false
            }
        }
    }
}

// MARK: - 沙盒文件搜索

enum LFileSearch {
    /// 递归遍历 Documents（限制深度与数量，避免卡住主线程）
    static func walk(extensions: Set<String>?, limit: Int = 5000) -> [FileEntry] {
        var out: [FileEntry] = []
        let fm = FileManager.default
        let showHidden = LSettings.shared.showHiddenFiles
        func visit(_ dir: String, depth: Int) {
            guard out.count < limit, depth < 12 else { return }
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in names {
                if name.hasPrefix(".") && !showHidden { continue }
                if name == "LANShareMedia" { continue }
                let full = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    visit(full, depth: depth + 1)
                } else {
                    let ext = (name as NSString).pathExtension.lowercased()
                    if let extensions, !extensions.contains(ext) { continue }
                    let attrs = try? fm.attributesOfItem(atPath: full)
                    out.append(FileEntry(name: name, path: full, isDirectory: false,
                                         size: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
                                         modified: (attrs?[.modificationDate] as? Date) ?? Date()))
                }
            }
        }
        visit(LFileStore.root, depth: 0)
        return LFileStore.sorted(out, LSettings.shared.fileSortMethod)
    }

    static func audioFiles() -> [FileEntry] {
        walk(extensions: MediaKind.audioExtensions)
    }

    /// flags: [图片, 视频, 音频, 其他]
    static func search(_ keyword: String, flags: [Bool]) -> [FileEntry] {
        let all = walk(extensions: nil)
        let lowered = keyword.lowercased()
        return all.filter { entry in
            guard entry.name.lowercased().contains(lowered) else { return false }
            let ext = (entry.name as NSString).pathExtension.lowercased()
            if MediaKind.isImage(ext) { return flag(flags, 0) }
            if MediaKind.isVideo(ext) { return flag(flags, 1) }
            if MediaKind.isAudio(ext) { return flag(flags, 2) }
            return flag(flags, 3)
        }
    }

    private static func flag(_ flags: [Bool], _ index: Int) -> Bool {
        flags.indices.contains(index) ? flags[index] : true
    }
}
