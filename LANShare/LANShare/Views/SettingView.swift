import SwiftUI

/// 设置页 (Android: SettingActivity + config/PreConfig.java)
struct SettingView: View {
    @StateObject private var settings = LSettings.shared
    @StateObject private var service = LANService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var editingPath = false
    @State private var pathDraft = ""
    @State private var editingKey = false
    @State private var keyDraft = ""
    @State private var tcpPortText = ""
    @State private var udpPortText = ""
    @State private var restartPrompt = false
    @State private var showThemePicker = false
    @State private var showPrivacy = false

    var body: some View {
        Form {
            generalSection
            switchesSection
            mediaSection
            fileSection
            Section {
                Button("隐私声明", action: { showPrivacy = true })
                Button("恢复默认设置") { restoreDefaults() }
                    .foregroundStyle(.red)
            } footer: {
                Text("修改端口后需要重启服务才能生效。")
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            tcpPortText = String(settings.tcpPort)
            udpPortText = String(settings.udpPort)
        }
        .alert("端口已修改", isPresented: $restartPrompt) {
            Button("稍后") {}
            Button("重启服务") {
                service.stop()
                service.start()
                service.showToast("服务已重启")
            }
        } message: {
            Text("新的端口需要重启服务后生效，局域网内其他设备也需要重新发现您。")
        }
        .sheet(isPresented: $showPrivacy) {
            PrivacySheet { settings.markPrivacyAgreed() }
        }
    }

    // MARK: - 通用设置

    private var generalSection: some View {
        Section {
            actionRow("设置设备名称", settings.devName, "修改") {
                nameDraft = settings.devName
                editingName = true
            }
            .alert("设置设备名称", isPresented: $editingName) {
                TextField("设备名称", text: $nameDraft)
                Button("确定") {
                    let value = nameDraft.trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty {
                        settings.devName = value
                        service.deviceManager.refreshLocalDevices()
                        service.deviceManager.notifyAllDevicesOnline()
                    }
                }
                Button("取消", role: .cancel) {}
            }

            actionRow("设置主题", settings.themeMode.label, "选择") { showThemePicker = true }
                .sheet(isPresented: $showThemePicker) { ThemePickerSheet() }

            actionRow("设置文件储存路径", settings.relativeFilePath, "修改") {
                pathDraft = settings.relativeFilePath
                editingPath = true
            }
            .alert("接收路径", isPresented: $editingPath) {
                TextField("相对路径", text: $pathDraft)
                Button("确定") {
                    if !pathDraft.isEmpty { settings.relativeFilePath = pathDraft }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("相对于“文件”App 中 LANShare 目录的路径，例如 LANShare")
            }

            actionRow("消息加密密钥", settings.messageKey.isEmpty ? "未设置" : "已设置", "修改") {
                keyDraft = settings.messageKey
                editingKey = true
            }
            .alert("消息加密密钥", isPresented: $editingKey) {
                SecureField("密钥", text: $keyDraft)
                Button("确定") { applyMessageKey() }
                Button("恢复默认") {
                    settings.messageKeyCipher = LConst.defaultMessageKey
                    service.showToast("已恢复默认密钥")
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("需与对端一致才能收发聊天消息。密钥会以加密形式保存。")
            }

            portRow("文件接收/网页服务端口", value: $tcpPortText) { applyTcpPort($0) }
            portRow("UDP端口(不建议更改)", value: $udpPortText) { applyUdpPort($0) }

            VStack(alignment: .leading) {
                Text("设置全局顶部外边距：\(settings.topMargin)")
                Slider(value: Binding(get: { Double(settings.topMargin) },
                                     set: { settings.topMargin = Int($0) }), in: 0...40, step: 1)
            }
        } header: {
            Text("通用设置")
        }
    }

    private func actionRow(_ title: String, _ value: String, _ button: String,
                           action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            Button(button, action: action)
        }
    }

    private func portRow(_ title: String, value: Binding<String>, apply: @escaping (Int) -> Void) -> some View {
        HStack {
            TextField(title, text: value)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
            Button("保存") {
                if let port = Int(value.wrappedValue), port > 0, port < 65_536 { apply(port) }
            }
            .buttonStyle(.bordered)
        }
    }

    private func applyTcpPort(_ port: Int) {
        guard port != settings.tcpPort else { return }
        settings.tcpPort = port
        restartPrompt = true
    }

    private func applyUdpPort(_ port: Int) {
        guard port != settings.udpPort else { return }
        settings.udpPort = port
        restartPrompt = true
    }

    private func applyMessageKey() {
        let text = keyDraft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let cipher = LCrypto.encryptMessage(text, key: LConst.key) else {
            service.showToast("密钥不能为空")
            return
        }
        settings.messageKeyCipher = cipher
        service.showToast("消息密钥已更新")
    }

    // MARK: - 功能开关

    private var switchesSection: some View {
        Section("功能开关") {
            LToggle("接收文件无需确认", detail: "开启时收到文件将不再提示", isOn: $settings.notRecvDialog)
            LToggle("加密传输文件", detail: "开启后传输文件时加密数据包，但同时传输速度会极大减少", isOn: $settings.encData)
            LToggle("开启网页文件访问", detail: "开启后可使用网页界面上传下载文件或者发送消息", isOn: $settings.webService)
            LToggle("网页开放局域网访问(不安全)", detail: "开启后在局域网可直接访问LANShare网页服务，不需要在手机端同意，开启此选项可能会造成数据泄露，请谨慎开启", isOn: $settings.webOpen)
            LToggle("保存消息记录", detail: "开启后会保存所有消息内容", isOn: $settings.saveMessage)
            LToggle("单个设备发送文件时默认选中此设备", detail: "设备列表中只有一个设备时默认选中此设备发送文件", isOn: $settings.defaultSelectOnlyOneDevice)
            LToggle("显示隐藏文件", detail: "文件管理中是否显示隐藏的文件", isOn: $settings.showHiddenFiles)
        }
    }

    // MARK: - 媒体设置

    private var mediaSection: some View {
        Section("媒体设置") {
            LToggle("保存媒体到相册", detail: "开启后接收到媒体文件会直接添加到相册", isOn: $settings.saveToGallery)
            LToggle("媒体默认为选择模式", detail: "开启后点击媒体将只会选中", isOn: $settings.mediaSelectModel)
            LToggle("使用内置编辑器打开媒体", detail: "使用内置播放器打开媒体文件", isOn: $settings.openMediaOnInternalPlayer)
            LToggle("媒体同步", detail: "媒体同步总开关，只有开启后才能自动同步媒体", isOn: $settings.mediaSync)
        }
    }

    // MARK: - 文件管理设置

    private var fileSection: some View {
        Section("文件管理设置") {
            LToggle("文件浏览路径保存", detail: "文件浏览界面保存上次浏览位置", isOn: $settings.saveLastFilePath)
            LToggle("收到文件时不分类保存", detail: "开启后收到文件不会进行文件夹分类存储", isOn: $settings.saveFilesCategoryPref)
            Picker("文件排序方式", selection: $settings.fileSortMethod) {
                ForEach(FileSortMethod.allCases) { Text($0.label).tag($0) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("搜索文件分类")
                Toggle("图片", isOn: searchFlag(0))
                Toggle("视频", isOn: searchFlag(1))
                Toggle("音频", isOn: searchFlag(2))
                Toggle("其他", isOn: searchFlag(3))
            }
        }
    }

    private func searchFlag(_ index: Int) -> Binding<Bool> {
        Binding(get: {
            settings.searchFlags.indices.contains(index) ? settings.searchFlags[index] : true
        }, set: { newValue in
            var flags = settings.searchFlags
            guard flags.indices.contains(index) else { return }
            flags[index] = newValue
            settings.searchFlags = flags
        })
    }

    private func restoreDefaults() {
        settings.notRecvDialog = true
        settings.encData = false
        settings.webService = true
        settings.webOpen = false
        settings.saveMessage = true
        settings.showHiddenFiles = false
        settings.relativeFilePath = LConst.defaultFileSavePath
        settings.tcpPort = LConst.defaultFileServerPort
        settings.udpPort = LConst.defaultUdpPort
        settings.messageKeyCipher = LConst.defaultMessageKey
        service.showToast("已恢复默认设置")
    }
}

/// Android: activity_setting.xml 的开关行 —— 标题 + 12sp 说明 + 右侧开关
private struct LToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    init(_ title: String, detail: String, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(LColor.textSecondary)
            }
            .padding(.vertical, 2)
        }
    }
}

/// 主题选择 (Android: 光明/暗黑/翠绿/跟随系统)
struct ThemePickerSheet: View {
    @StateObject private var settings = LSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(ThemeMode.allCases) { mode in
                    Button {
                        settings.themeMode = mode
                        dismiss()
                    } label: {
                        HStack {
                            Circle().fill(swatch(mode)).frame(width: 20, height: 20)
                            Text(mode.label)
                            Spacer()
                            if settings.themeMode == mode {
                                Image(systemName: "checkmark").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("设置主题")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func swatch(_ mode: ThemeMode) -> Color {
        switch mode {
        case .light: return .white
        case .dark: return .black
        case .emerald: return Color(uiColor: LPalette.emerald.primary)
        case .followSystem: return .gray
        }
    }
}

// MARK: - 关于页 (Android: AboutActivity + activity_about.xml)

struct AboutView: View {
    @StateObject private var service = LANService.shared
    @State private var taps = 0
    @State private var showBuild = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    // Android: activity_about.xml 用 ic_launcher_round 作为封面
                    Image("ic_launcher_round")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text(LConst.appName).font(.title2.bold())
                    Text("V\(LFormat.version)").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .contentShape(Rectangle())
                .onTapGesture {
                    taps += 1
                    if taps >= 3 {
                        taps = 0
                        showBuild = true
                    }
                }
            }
            Section {
                Link(destination: URL(string: LConst.server)!) { aboutLabel("官网首页") }
                Link(destination: URL(string: LConst.github)!) { aboutLabel("Github") }
                Button(action: { showHelp = true }) { aboutLabel("使用帮助") }
                Button(action: { showPrivacy = true }) { aboutLabel("隐私声明") }
                Button(action: { showWeb = true }) { aboutLabel("网页客户端") }
            } footer: {
                Text("版权所有©fgsq")
            }
            Section("运行状态") {
                LabeledContent("服务", value: service.isRunning ? "运行中" : "已停止")
                LabeledContent("本机地址", value: service.deviceManager.selfDevices
                    .filter { $0.isIPv4 }.map(\.devIP).joined(separator: ", ") )
                LabeledContent("在线设备", value: "\(service.devices.count)")
                LabeledContent("TCP 端口", value: "\(LSettings.shared.tcpPort)")
                LabeledContent("UDP 端口", value: "\(LSettings.shared.udpPort)")
                LabeledContent("协议版本", value: "V\(LConst.dataVersion)")
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showBuild) {
            BuildInfoSheet()
        }
        .sheet(isPresented: $showPrivacy) {
            PrivacySheet { LSettings.shared.markPrivacyAgreed() }
        }
        .sheet(isPresented: $showHelp) {
            HelpSheet()
        }
        .sheet(isPresented: $showWeb) {
            WebAddressSheet()
        }
    }

    /// Android: 关于页每行右侧的 ic_next 箭头
    private func aboutLabel(_ title: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(LColor.textPrimary)
            Spacer()
            Image(systemName: "chevron.forward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LColor.textTertiary)
        }
        .contentShape(Rectangle())
    }

    @State private var showHelp = false
    @State private var showPrivacy = false
    @State private var showWeb = false
}

private struct BuildInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "-")
                LabeledContent("版本", value: LFormat.version)
                LabeledContent("构建", value: (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "-")
                LabeledContent("系统", value: UIDevice.current.systemVersion)
                LabeledContent("设备", value: UIDevice.current.name)
                LabeledContent("UUID", value: LSettings.shared.uniqueUUid)
            }
            .navigationTitle("构建信息")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("好") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

private struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    helpRow("1. 连接同一个 Wi-Fi", "LANShare 只在局域网内工作，请确认手机与电脑/其他手机连到同一路由器。")
                    helpRow("2. 允许本地网络权限", "首次发送广播时系统会弹窗询问，选择“允许”。未授权时搜索不到设备。")
                    helpRow("3. 发送文件", "在“文件”页勾选文件，底部点击“发送”，再选择目标设备。")
                    helpRow("4. 聊天", "在“记录”页输入内容后点击发送；长按发送键内容会写入对方剪贴板。")
                    helpRow("5. 网页端", "开启网页服务后，浏览器访问 http://本机IP:\(LConst.defaultFileServerPort) 即可上传下载。")
                    helpRow("6. 断点续传", "V5 版本传输中断后，重新发送同一文件会从已接收位置继续。")
                }
                .padding()
            }
            .navigationTitle("使用帮助")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func helpRow(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
