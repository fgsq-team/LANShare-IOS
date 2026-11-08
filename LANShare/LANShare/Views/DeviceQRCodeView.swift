import SwiftUI
import UIKit

/// 二维码页 (Android: DeviceQrCodeActivity + add_device_qrcode.xml)
struct DeviceQRCodeView: View {
    @StateObject private var service = LANService.shared
    @State private var showScanner = false
    @State private var scanned: String?
    @State private var showWeb = false

    private var qrContent: String { service.makeQRContent() }
    private var webAddress: String { "http://\(LAppModel.shared.webHost):\(LSettings.shared.tcpPort)" }

    var body: some View {
        Form {
            Section("添加设备") {
                VStack(spacing: 12) {
                    QRCodeImageView(content: qrContent)
                        .frame(width: 220, height: 220)
                    Text(qrContent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Button("长按复制地址") { LAppModel.shared.copyToPasteboard(qrContent) }
                        Button("扫码连接") { showScanner = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section("本机地址") {
                ForEach(service.deviceManager.selfDevices.filter { !$0.devIP.isEmpty }) { device in
                    LabeledContent(device.isIPv4 ? "IPv4" : "IPv6", value: device.devIP)
                        .contentShape(Rectangle())
                        .onLongPressGesture { LAppModel.shared.copyToPasteboard(device.devIP) }
                }
                LabeledContent("TCP 端口", value: "\(LSettings.shared.tcpPort)")
                LabeledContent("UDP 端口", value: "\(LSettings.shared.udpPort)")
                Button("网页二维码") { showWeb = true }
            }

            Section("在线设备") {
                if service.devices.isEmpty {
                    Text("在局域网中没有搜索到设备").foregroundStyle(.secondary)
                }
                ForEach(service.devices) { device in
                    HStack {
                        LDeviceIcon(name: DeviceIcon.of(device.type), side: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(device.devName) (V\(device.dataVersion))")
                            Text(device.address).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("发送") {
                            LAppModel.shared.chatTarget = device
                        }
                    }
                }
            }

            if let scanned {
                Section("扫码结果") {
                    Text(scanned).font(.caption.monospaced())
                }
            }
        }
        .navigationTitle("二维码")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                handle(code)
            }
        }
        .sheet(isPresented: $showWeb) {
            WebAddressSheet()
        }
    }

    /// 与 Android 一致：匹配 KEY 前缀走配对，否则把内容粘贴到聊天输入
    private func handle(_ code: String) {
        scanned = code
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
            service.showToast("已复制到剪贴板")
            UIPasteboard.general.string = code
        }
    }
}

// MARK: - 网页客户端管理 (Android: WebClientManagerActivity + TokenDBUtil)

struct WebClientManagerView: View {
    @StateObject private var service = LANService.shared
    @State private var tokens: [LToken] = []
    @State private var newIP = ""
    @State private var showAdd = false

    var body: some View {
        List {
            Section {
                ForEach(tokens, id: \.token) { token in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(token.name.isEmpty ? "未命名客户端" : token.name)
                            Spacer()
                            if token.pass == 1 {
                                Text("已授权").font(.caption).foregroundStyle(.green)
                            } else {
                                Text("待授权").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Text("\(token.ip) · \(token.token)").font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            service.tokenDB.delete(token: token.token)
                            reload()
                        }
                        Button("允许") {
                            service.tokenDB.setPass(token: token.token, pass: 1)
                            reload()
                        }
                        .tint(.green)
                    }
                    .contextMenu {
                        Button("复制网页地址") {
                            LAppModel.shared.copyToPasteboard("http://\(token.ip):\(LSettings.shared.tcpPort)")
                        }
                        Button("撤销授权") {
                            service.tokenDB.setPass(token: token.token, pass: 0)
                            reload()
                        }
                    }
                }
            } header: {
                HStack {
                    Text("网页授权列表")
                    Spacer()
                    Button("添加") { showAdd = true }
                }
                .font(.footnote)
            } footer: {
                Text(tokens.isEmpty ? "暂无授权的客户端" : "")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("网页客户端管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .refreshable { reload() }
        .alert("添加授权", isPresented: $showAdd) {
            TextField("客户端 IP", text: $newIP)
                .keyboardType(.numbersAndPunctuation)
            Button("确定") {
                guard !newIP.isEmpty else { return }
                let token = LCrypto.md5Hex("\(LSettings.shared.uniqueUUid)-\(newIP)")
                service.tokenDB.add(token: token, custom: true, pass: 1, ip: newIP, name: "手动添加")
                reload()
            }
            Button("取消", role: .cancel) { newIP = "" }
        } message: {
            Text("输入局域网内其他设备的 IP，将为它生成一个已授权的访问令牌。")
        }
    }

    private func reload() {
        tokens = service.tokenDB.queryList()
    }
}

// MARK: - 文件同步管理 (Android: FileSyncManagerActivity + FileSyncDBUtil)

struct FileSyncManagerView: View {
    @StateObject private var service = LANService.shared
    @State private var rows: [LFileSyncData] = []

    var body: some View {
        List {
            Section {
                ForEach(rows, id: \.deviceId) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.deviceName)
                        Text(row.folderPath).font(.caption).foregroundStyle(.secondary)
                        Text("同步目录：\(row.name)").font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            service.fileSyncDB.delete(deviceId: row.deviceId)
                            reload()
                        }
                    }
                }
            } header: {
                Text("文件同步设备")
                    .font(.footnote)
            } footer: {
                Text(rows.isEmpty ? "暂无同步设备" : "对端请求同步某个目录后会自动记录在这里。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("文件同步管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .refreshable { reload() }
    }

    private func reload() {
        rows = service.fileSyncDB.queryList()
    }
}
