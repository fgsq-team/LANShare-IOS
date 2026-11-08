import SwiftUI
import Combine
import UIKit

/// 远程绘图 (Android: DrawingActivity + activity_drawing.xml)
struct DrawingView: View {
    @StateObject private var service = LANService.shared
    @StateObject private var canvas = LDrawCanvas()
    @Environment(\.dismiss) private var dismiss

    @State private var mode: LDrawSyncManager.SyncMode = .web
    @State private var colorHex = 0xFF000000
    @State private var strokeWidth: Float = 4
    @State private var connectedName = ""
    @State private var statusText = "未连接"
    @State private var showDevicePicker = false

    private let palette: [(String, Int)] = [
        ("黑色", 0xFF00_0000), ("红色", 0xFFFF_3B30), ("蓝色", 0xFF0A_84FF),
        ("绿色", 0xFF34_C759), ("黄色", 0xFFFF_CC00), ("白色", 0xFFFF_FFFF),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            canvasView
            controlPanel
        }
        .navigationTitle("远程绘图")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("退出") { leave() }
            }
        }
        .onAppear(perform: attach)
        .onDisappear {
            manager.onRemoteDraw = nil
            if mode == .device { manager.disconnect() }
        }
        .sheet(isPresented: $showDevicePicker) {
            DeviceSelectSheet(title: "选择同步设备", showAllDevices: false) { device in
                if let device { bind(device) }
            }
        }
    }

    private var manager: LDrawSyncManager { service.drawSyncManager }

    // MARK: - 顶部状态

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: $mode) {
                Text("网页同步").tag(LDrawSyncManager.SyncMode.web)
                Text("设备同步").tag(LDrawSyncManager.SyncMode.device)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            .onChange(of: mode) { _, value in switchMode(value) }

            if mode == .device {
                Button(connectedName.isEmpty ? "选择设备" : connectedName) { showDevicePicker = true }
                    .buttonStyle(.bordered)
            }
            Spacer()
            Text(statusText).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - 画布

    private var canvasView: some View {
        Canvas { context, size in
            for stroke in canvas.strokes {
                guard stroke.points.count > 1 else { continue }
                var path = Path()
                path.move(to: stroke.points[0])
                for point in stroke.points.dropFirst() {
                    path.addLine(to: point)
                }
                context.stroke(path, with: .color(stroke.uiColor),
                               style: StrokeStyle(lineWidth: CGFloat(stroke.width), lineCap: .round, lineJoin: .round))
            }
        }
        .background(Color(.systemBackground))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !canvas.drawing {
                        canvas.begin(color: colorHex, width: strokeWidth)
                        emit(action: "start", at: value.location)
                    }
                    let point = CGPoint(x: value.location.x, y: value.location.y)
                    canvas.extend(to: point)
                    emit(action: "move", at: point)
                }
                .onEnded { value in
                    canvas.end()
                    emit(action: "end", at: value.location)
                }
        )
    }

    // MARK: - 控制面板

    private var controlPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(palette, id: \.0) { item in
                    Button {
                        colorHex = item.1
                    } label: {
                        Circle()
                            .fill(Color(uiColor: UIColor(hex: item.1)))
                            .frame(width: 24, height: 24)
                            .overlay(Circle().stroke(colorHex == item.1 ? Color.primary : Color.clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button {
                    canvas.clear()
                    service.httpServer?.sendClearDraw()
                } label: {
                    Label("清除画布", systemImage: "trash")
                }
            }
            HStack {
                Text("粗细")
                Slider(value: $strokeWidth, in: 1...30, step: 1)
                Text("\(Int(strokeWidth))pt").font(.caption).frame(width: 40, alignment: .trailing)
            }
            HStack {
                Text("当前画笔")
                Circle().fill(Color(uiColor: UIColor(hex: colorHex))).frame(width: CGFloat(strokeWidth), height: CGFloat(strokeWidth))
                Spacer()
                Text("对方笔迹会实时出现在画布上").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.bar)
    }

    // MARK: - 事件

    private func attach() {
        manager.onRemoteDraw = { event in
            DispatchQueue.main.async {
                self.canvas.apply(event: event)
            }
        }
        manager.onConnected = { device in
            DispatchQueue.main.async {
                self.connectedName = device.devName
                self.statusText = "已连接 \(device.devName)"
            }
        }
        manager.onConnectFailed = { _, reason in
            DispatchQueue.main.async {
                self.statusText = "连接失败：\(reason)"
            }
        }
        manager.onDisconnected = { device in
            DispatchQueue.main.async {
                self.statusText = "\(device.devName) 已断开"
                self.connectedName = ""
            }
        }
        if let device = manager.device, manager.isConnected {
            connectedName = device.devName
            statusText = "已连接 \(device.devName)"
            mode = .device
        }
    }

    private func switchMode(_ value: LDrawSyncManager.SyncMode) {
        switch value {
        case .web:
            manager.disconnect()
            connectedName = ""
            statusText = service.httpServer == nil ? "网页服务未开启" : "同步到网页端"
        case .device:
            if let device = manager.device, manager.isConnected {
                statusText = "已连接 \(device.devName)"
            } else {
                showDevicePicker = true
                statusText = "未连接"
            }
        }
    }

    private func bind(_ device: Device) {
        statusText = "正在连接 \(device.devName)…"
        manager.connect(to: device, service: service)
    }

    private func emit(action: String, at point: CGPoint) {
        let event = LDrawEvent(action: action, x: Float(point.x), y: Float(point.y),
                               color: colorHex, strokeWidth: strokeWidth)
        switch mode {
        case .device:
            manager.sendDrawEvent(event)
        case .web:
            service.httpServer?.sendDrawEvent(event.jsonString)
        }
    }

    private func leave() {
        manager.disconnect()
        dismiss()
    }
}

// MARK: - 画布数据

final class LDrawCanvas: ObservableObject {
    struct Stroke {
        var color: Int
        var width: Float
        var points: [CGPoint]

        var uiColor: Color { Color(uiColor: UIColor(hex: color)) }
    }

    @Published var strokes: [Stroke] = []
    private(set) var drawing = false
    private var currentColor = 0xFF00_0000
    private var currentWidth: Float = 4
    /// 远端事件按 sessionId 归组，key = 颜色+宽度
    private var remoteOpen = false

    func begin(color: Int, width: Float) {
        drawing = true
        currentColor = color
        currentWidth = width
        strokes.append(Stroke(color: color, width: width, points: []))
    }

    func extend(to point: CGPoint) {
        guard drawing, var last = strokes.popLast() else { return }
        last.points.append(point)
        strokes.append(last)
    }

    func end() {
        drawing = false
    }

    func clear() {
        strokes.removeAll()
        remoteOpen = false
    }

    /// 应用远端事件（Android/Web 发来的绝对坐标）
    func apply(event: LDrawEvent) {
        let point = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))
        let width = max(event.strokeWidth, 1)
        switch event.action {
        case "start":
            remoteOpen = true
            strokes.append(Stroke(color: event.color, width: width, points: []))
        case "move":
            guard remoteOpen, var last = strokes.popLast() else {
                strokes.append(Stroke(color: event.color, width: width, points: [point]))
                return
            }
            last.points.append(point)
            strokes.append(last)
        case "end":
            remoteOpen = false
            if var last = strokes.popLast() {
                last.points.append(point)
                strokes.append(last)
            }
        default:
            break
        }
    }
}

extension UIColor {
    /// 0xAARRGGBB（与 AndroidDrawingActivity 的 color 字段一致）
    convenience init(hex: Int) {
        let a = CGFloat((hex >> 24) & 0xFF) / 255
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
