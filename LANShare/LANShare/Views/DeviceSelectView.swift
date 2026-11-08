import SwiftUI
import Combine

/// 设备选择弹窗 (Android: DeviceSelectDialog + device_select.xml)
struct DeviceSelectSheet: View {
    let title: String
    let showAllDevices: Bool
    let onPick: (Device?) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = LANService.shared
    @State private var refreshTick = 0

    var body: some View {
        NavigationStack {
            Group {
                if service.devices.isEmpty {
                    ContentUnavailableView("在局域网中没有搜索到设备", systemImage: "wifi.slash",
                                           description: Text("请确认设备与本机连接同一个无线网络"))
                } else {
                    List {
                        Section {
                            if showAllDevices {
                                row(name: LConst.allDevicesKey, ip: "广播到所有在线设备", icon: "square.stack.3d.up",
                                    battery: "", device: nil)
                            }
                            ForEach(service.devices) { device in
                                row(device: device)
                            }
                        } header: {
                            // Android: FileSendDialog 的 dev_dialog_count_tv
                            let n = FilesSelection.shared.count
                            Text(n > 0 ? "已选择 \(n) 个文件" : "在局域网中搜索到的设备")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // 取消不能回调 nil，否则与「广播到所有在线设备」无法区分，会误发并清空已选
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        service.deviceManager.notifyAllDevicesOnline()
                        refreshTick += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                refreshTick += 1
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(name: String, ip: String, icon: String, battery: String, device: Device?) -> some View {
        Button {
            finish(device)
        } label: {
            DeviceRow(name: name, ip: ip, icon: icon, battery: battery, device: device)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let device {
                Button("复制IP") { LAppModel.shared.copyToPasteboard(device.devIP) }
                Button("复制设备名") { LAppModel.shared.copyToPasteboard(device.devName) }
                if device.isWeb {
                    Button("复制网页地址") {
                        LAppModel.shared.copyToPasteboard("http://\(device.devIP):\(LSettings.shared.tcpPort)")
                    }
                }
                Button("复制所有") {
                    LAppModel.shared.copyToPasteboard("\(device.devName)\n\(device.devIP)\n\(device.address)")
                }
            }
        }
    }

    private func row(device: Device) -> some View {
        row(name: "\(device.devName) (V\(device.dataVersion))",
            ip: device.devIP,
            icon: DeviceIcon.of(device.type),
            battery: device.batteryText,
            device: device)
    }

    private func finish(_ device: Device?) {
        onPick(device)
        dismiss()
    }
}

/// Android: device_select_item.xml — 60dp 行 / 50dp 图标 / 160dp 文字列 / 20dp 电量图标 + 电量百分比
struct DeviceRow: View {
    let name: String
    let ip: String
    let icon: String
    let battery: String
    let device: Device?

    var body: some View {
        HStack(spacing: 10) {
            iconView
                .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(LColor.textPrimary)
                    .lineLimit(1)
                Text(ip.isEmpty ? "本机广播" : ip)
                    .font(.system(size: 10))
                    .foregroundStyle(LColor.deviceInfoText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 160, alignment: .leading)
            Spacer(minLength: 4)
            if let device, device.batteryLevel >= 0 {
                HStack(spacing: 3) {
                    Image(systemName: device.chargeStatus != 0 ? "battery.100.bolt" : batterySymbol(device))
                    Text(battery)
                }
                .font(.system(size: 10))
                .foregroundStyle(LColor.limeGreen)
            }
        }
        .frame(height: 60)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var iconView: some View {
        LDeviceIcon(name: icon, side: 40)
    }

    private func batterySymbol(_ device: Device) -> String {
        switch device.batteryLevel {
        case ..<10: return "battery.0"
        case ..<35: return "battery.25"
        case ..<70: return "battery.50"
        default: return "battery.100"
        }
    }
}

enum DeviceIcon {
    static func of(_ mode: DevMode) -> String {
        switch mode {
        case .android, .ios, .harmonyOs: return "ic_phone"
        case .windows, .linux, .macOs: return "ic_pc"
        case .web: return "globe"
        case .unknow: return "questionmark.circle"
        }
    }
}

/// 手机/电脑沿用安卓切图（模板色跟随主题），其余用 SF Symbol
struct LDeviceIcon: View {
    let name: String
    var side: CGFloat = 40

    var body: some View {
        if name == "ic_phone" || name == "ic_pc" {
            Image(name)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: side, height: side)
                .foregroundStyle(LColor.icon)
        } else {
            Image(systemName: name)
                .font(.system(size: side * 0.65))
                .foregroundStyle(LColor.icon)
        }
    }
}
