import SwiftUI
import UIKit

/// 主界面 (Android: DataCenterActivity + main.xml + base_toobar.xml + mian_bottom.xml)
struct RootView: View {
    @StateObject private var service = LANService.shared
    @StateObject private var settings = LSettings.shared
    @StateObject private var app = LAppModel.shared
    @StateObject private var filesSelection = FilesSelection.shared
    @StateObject private var chatSelection = ChatSelection.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab: RootTab = .chat
    @State private var showSettings = false
    @State private var showAbout = false
    @State private var showQR = false
    @State private var showScanner = false
    @State private var showWebQR = false
    @State private var showClearMessages = false
    @State private var showTokens = false
    @State private var showFileSync = false
    @State private var showDrawing = false
    @State private var showPrivacy = false
    @State private var showSortMenu = false
    @State private var showSearchTypes = false
    /// Android: 连点“记录”5 次唤出工具栏菜单
    @State private var recordTaps = 0
    @State private var showEggMenu = false

    enum RootTab: Hashable {
        case chat, files
    }

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .chat: ChatView()
                case .files: FilesView()
                }
            }
            .toolbar { toolbarContent }
            .toolbarBackground(LColor.toolbarBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomArea }
            .alert("新的网页客户端请求", isPresented: webClientBinding) {
                Button("不同意", role: .cancel) { service.resolveWebClientApproval(isAgree: false) }
                Button("同意") { service.resolveWebClientApproval(isAgree: true) }
            } message: {
                Text("是否同意此客户端访问手机文件?")
            }
            .navigationDestination(isPresented: $showSettings) { SettingView() }
            .navigationDestination(isPresented: $showAbout) { AboutView() }
            .navigationDestination(isPresented: $showQR) { DeviceQRCodeView() }
            .navigationDestination(isPresented: $showDrawing) { DrawingView() }
            .navigationDestination(isPresented: $showTokens) { WebClientManagerView() }
            .navigationDestination(isPresented: $showFileSync) { FileSyncManagerView() }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(LColor.primary)
        .preferredColorScheme(settings.themeMode.colorScheme)
        .lanToast(service)
        .sheet(item: $app.devicePicker) { request in
            DeviceSelectSheet(title: request.title, showAllDevices: request.showAllDevices) { device in
                request.completion(device)
            }
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                handleScanned(code)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showWebQR) {
            WebAddressSheet()
        }
        .sheet(isPresented: $app.showQuickLook) {
            QuickLookSheet(urls: app.quickLook)
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $app.showImagePreview) {
            ImageViewerSheet(pages: app.imagePages, index: app.imageIndex)
        }
        .fullScreenCover(item: $app.videoPreview) { item in
            VideoPlayerSheet(url: item.url)
                .ignoresSafeArea()
        }
        .alert("是否接收文件?", isPresented: receiveBinding) {
            Button("不同意", role: .cancel) { service.resolveReceiveApproval(isAgree: false) }
            Button("同意") { service.resolveReceiveApproval(isAgree: true) }
        } message: {
            if let pending = service.pendingReceive {
                Text("是否接收来自\(pending.deviceName)的\(pending.count)个文件\n共 \(pending.sizeText)")
            } else {
                Text("")
            }
        }
        .alert("绘图同步请求", isPresented: drawSyncBinding) {
            Button("拒绝", role: .cancel) { service.resolveDrawSync(accepted: false) }
            Button("接受") { service.resolveDrawSync(accepted: true) }
        } message: {
            Text("设备 \"\(service.pendingDrawSync?.requesterName ?? "")\" 请求与您同步绘图，是否接受？")
        }
        .confirmationDialog("清理消息", isPresented: $showClearMessages, titleVisibility: .visible) {
            Button("清空所有消息") { service.clearMessages() }
            Button("清空文本") { service.clearMessages(ofTypes: [1]) }
            Button("清空文件") { service.clearMessages(ofTypes: [3]) }
            Button("清空已删除文件") { service.clearMissingFileMessages() }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showPrivacy) {
            PrivacySheet {
                settings.markPrivacyAgreed()
                showPrivacy = false
                service.start()
            }
        }
        .sheet(isPresented: $showSortMenu) { SortMethodSheet() }
        .sheet(isPresented: $showSearchTypes) { SearchTypesSheet() }
        .confirmationDialog("菜单", isPresented: $showEggMenu, titleVisibility: .hidden) {
            menuActions
            Button("取消", role: .cancel) {}
        }
        .onAppear {
            if settings.privacyAgreed {
                service.start()
            } else {
                showPrivacy = true
            }
            service.onDeviceQrCodeScanned = { showScanner = false }
            service.openDrawingReceiverHandler = { _, _ in showDrawing = true }
        }
        .onDisappear {
            service.onDeviceQrCodeScanned = nil
            service.openDrawingReceiverHandler = nil
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                service.start()
                service.checkNetworkChange()
            case .background: break
            default: break
            }
        }
    }

    /// 扫码结果处理 (Android: onActivityResult → FS_ADD_DEVICE)
    private func handleScanned(_ code: String) {
        if code.hasPrefix(LConst.key) {
            service.scanQR(code) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let device):
                        service.showToast("添加设备\(device.devName) 成功")
                    case .failure(let error):
                        service.showToast("添加设备失败：\(error.localizedDescription)")
                    }
                }
            }
        } else {
            // Android: 非设备二维码时把内容填入聊天输入框
            chatSelection.draft = code
            service.showToast("已填入输入框")
        }
    }

    private var receiveBinding: Binding<Bool> {
        Binding(get: { service.pendingReceive != nil },
                set: { if !$0 { service.resolveReceiveApproval(isAgree: false) } })
    }

    private var drawSyncBinding: Binding<Bool> {
        Binding(get: { service.pendingDrawSync != nil },
                set: { if !$0 { service.resolveDrawSync(accepted: false) } })
    }

    private var webClientBinding: Binding<Bool> {
        Binding(get: { service.pendingWebClient != nil },
                set: { if !$0 { service.resolveWebClientApproval(isAgree: false) } })
    }

    // MARK: - 顶部工具栏 (Android: layout/base_toobar.xml)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { toolbarTitle }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 10) {
                Toggle("网页文件访问", isOn: $settings.webService)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("网页文件访问")
                Button {
                    showScanner = true
                } label: {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 20))
                        .foregroundStyle(LColor.icon)
                }
                .accessibilityLabel("扫码添加设备")
                .onLongPressGesture(minimumDuration: 0.4) { showQR = true }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu { menuActions } label: { Image(systemName: "ellipsis") }
        }
    }

    /// 应用名 + 本机地址 (Android: main_name 20sp 粗 / main_ip 13sp，点击弹网页二维码，长按复制)
    private var toolbarTitle: some View {
        Button {
            showWebQR = true
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(LConst.appName)
                    .font(.system(size: 20, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(LColor.toolbarText)
                Text(ipText)
                    .font(.system(size: 13))
                    .foregroundStyle(LColor.textSecondary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: 150, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("本机地址 \(ipText)")
        .onLongPressGesture(minimumDuration: 0.4) {
            app.copyToPasteboard(localIP)
            service.showToast("已复制到剪贴板")
        }
    }

    /// 溢出菜单 (Android: menu/toolbar_menu.xml；排序与搜索分类仅在文件页可见)
    @ViewBuilder
    private var menuActions: some View {
        Button("设置") { showSettings = true }
        Button("关于") { showAbout = true }
        Button("清理消息") { showClearMessages = true }
        Button("网页客户端管理") { showTokens = true }
        Button("媒体共享管理") { showFileSync = true }
        Button("远程绘图") { showDrawing = true }
        if tab == .files {
            Divider()
            Button("文件排序方式") { showSortMenu = true }
            Button("搜索文件分类") { showSearchTypes = true }
        }
        if !settings.privacyAgreed {
            Button("重新查看隐私声明") { showPrivacy = true }
        }
        Divider()
        Button("退出软件", role: .destructive) { exit(0) }
    }

    private var localIP: String {
        let locals = service.deviceManager.selfDevices
        return locals.first { $0.isIPv4 }?.devIP ?? locals.first?.devIP ?? ""
    }

    /// Android: refreshIpDisplay()，开启网页服务时直接显示可访问地址
    private var ipText: String {
        guard !localIP.isEmpty else { return "无网络" }
        guard settings.webService else { return localIP }
        let isV4 = service.deviceManager.selfDevices.first { $0.devIP == localIP }?.isIPv4 ?? true
        return "http://\(isV4 ? localIP : "[\(localIP)]"):\(settings.tcpPort)"
    }

    // MARK: - 底部导航 (Android: mian_bottom.xml)

    /// Android: 进入删除模式后底部导航整条换成删除栏
    @ViewBuilder
    private var bottomArea: some View {
        if chatSelection.deleteMode {
            deleteBar
        } else {
            navBar
        }
    }

    private var navBar: some View {
        HStack(spacing: 0) {
            navButton(title: "记录", icon: "note.text",
                      tint: tab == .chat ? LColor.textSelect : LColor.textNotSelect) {
                selectRecord()
            }
            navButton(title: "发送", icon: "paperplane.fill", tint: LColor.accent) {
                sendTapped()
            }
            navButton(title: filesTitle, icon: "folder.fill",
                      tint: tab == .files ? LColor.textSelect : LColor.textNotSelect) {
                recordTaps = 0
                tab = .files
            }
            .contextMenu {
                Button("清空已选") {
                    filesSelection.clear()
                    service.showToast("已清空选中数据")
                }
            }
        }
        .frame(height: 64)
        .frame(maxWidth: .infinity)
        .background(LColor.bottomBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(LColor.divider).frame(height: 1)
        }
        .shadow(color: LColor.shadow, radius: 4, y: -1)
    }

    private func navButton(title: String, icon: String, tint: Color,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(width: 26, height: 26)
                Text(title).font(.system(size: 11)).lineLimit(1)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Android: setSelectedCount()，有选中时“文件”变成“已选(N)”
    private var filesTitle: String {
        let count = filesSelection.count
        guard count > 0 else { return "文件" }
        return count > 999 ? "已选(999+)" : "已选(\(count))"
    }

    /// Android: bottom_record 点击 —— 3 次提示、5 次唤出菜单
    private func selectRecord() {
        recordTaps += 1
        if recordTaps == 3 {
            service.showToast("再点击两次唤出菜单")
        } else if recordTaps >= 5 {
            recordTaps = 0
            showEggMenu = true
        }
        tab = .chat
    }

    private func sendTapped() {
        recordTaps = 0
        guard !filesSelection.isEmpty else {
            service.showToast("请选择文件")
            return
        }
        filesSelection.send()
    }

    // MARK: - 删除栏 (Android: main.xml 的 bottom_delete_message)

    private var deleteBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("已选 \(chatSelection.selected.count) 项")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(LColor.toolbarText)
                .padding(.leading, 20)
                .padding(.top, 14)
                .padding(.bottom, 4)
            HStack(spacing: 0) {
                LTextButton("取消", tint: LColor.textSecondary) {
                    chatSelection.exit()
                }
                Spacer()
                LTextButton(chatSelection.isAllSelected(service.messages) ? "取消全选" : "全选",
                            tint: LColor.primary) {
                    chatSelection.toggleAll(service.messages)
                }
                Spacer()
                Button {
                    chatSelection.delete(service.messages)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash").font(.system(size: 15))
                        Text("删除").font(.system(size: 14))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(LColor.error.opacity(chatSelection.selected.isEmpty ? 0.4 : 1),
                                in: RoundedRectangle(cornerRadius: 10))
                }
                .disabled(chatSelection.selected.isEmpty)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .background(LColor.surface)
    }
}

// MARK: - 隐私声明 (Android: PrivacyDialog)

/// Android: privacy_dialog.xml — 居中标题「提示」+ 16sp 正文 + 不同意/同意 两个 50dp 平铺按钮
struct PrivacySheet: View {
    var onAgree: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("提示")
                .font(.system(size: 16))
                .foregroundStyle(LColor.textPrimary)
                .padding(.top, 10)
            VStack(alignment: .leading, spacing: 12) {
                Text("嗨，亲爱的用户，很高兴遇见你，为了您的隐私数据安全，在您使用 App 之前您需要仔细阅读《用户协议》和《隐私政策》。点击「同意」按钮代表您接受此政策和协议。")
                    .font(.system(size: 16))
                Text("本应用仅在局域网内共享文件与消息，不收集、不上传任何用户数据；首次运行时系统会请求「本地网络」权限，用于发现同一局域网中的其他设备，您有权拒绝授予。")
                    .font(.system(size: 16))
                    .foregroundStyle(LColor.textSecondary)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            Divider()
            HStack(spacing: 10) {
                LTextButton("不同意", tint: LColor.textSecondary) { exit(0) }
                    .frame(maxWidth: .infinity)
                LTextButton("同意") { onAgree() }
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 50)
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }
}

// MARK: - 网页地址 (Android: 点击 IP 弹出的 InfoDialog)

struct WebAddressSheet: View {
    @Environment(\.dismiss) private var dismiss
    private var address: String { "http://\(LAppModel.shared.webHost):\(LSettings.shared.tcpPort)" }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button("关闭") { dismiss() }
                Spacer()
                Text("网页客户端").font(.headline)
                Spacer()
                Button("复制") { LAppModel.shared.copyToPasteboard(address) }
            }
            QRCodeImageView(content: address)
                .frame(width: 220, height: 220)
            Text(address).font(.body.monospaced()).textSelection(.enabled)
            Text("同一局域网内的电脑或手机浏览器扫码即可访问").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(20)
        .presentationDetents([.medium])
    }
}

extension LAppModel {
    /// 网页访问优先使用 IPv4 地址
    var webHost: String {
        LANService.shared.deviceManager.selfDevices.first { $0.isIPv4 }?.devIP ?? "127.0.0.1"
    }
}

// MARK: - 排序方式 (Android: setShowSortFileMenu 单选 InfoDialog，取消则不生效)

struct SortMethodSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var picked = LSettings.shared.fileSortMethod

    var body: some View {
        NavigationStack {
            List(FileSortMethod.allCases) { method in
                Button {
                    picked = method
                } label: {
                    HStack {
                        Text(method.label).foregroundStyle(LColor.textPrimary)
                        Spacer()
                        if picked == method {
                            Image(systemName: "checkmark").foregroundStyle(LColor.primary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("选择排序方式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        LSettings.shared.fileSortMethod = picked
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - 搜索文件分类 (Android: setSearchFileTypes 多选 InfoDialog)

struct SearchTypesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var flags = LSettings.shared.searchFlags

    private let titles = ["图片", "视频", "音频", "其他"]

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                    Toggle(title, isOn: binding(index))
                }
            }
            .navigationTitle("搜索文件分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        LSettings.shared.searchFlags = flags
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(260)])
    }

    private func binding(_ index: Int) -> Binding<Bool> {
        Binding(get: { flags.indices.contains(index) ? flags[index] : true },
                set: { newValue in
                    guard flags.indices.contains(index) else { return }
                    flags[index] = newValue
                })
    }
}

#Preview {
    RootView()
}
