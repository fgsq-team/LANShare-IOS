import Foundation

/// 绘图同步事件 (Android: DrawingView 的 action/x/y/color/strokeWidth)
struct LDrawEvent {
    let action: String
    let x: Float
    let y: Float
    /// 0xAARRGGBB
    let color: Int
    let strokeWidth: Float

    static func from(jsonString: String) -> LDrawEvent? {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = obj["action"] as? String else { return nil }
        return LDrawEvent(action: action,
                          x: (obj["x"] as? NSNumber)?.floatValue ?? 0,
                          y: (obj["y"] as? NSNumber)?.floatValue ?? 0,
                          color: (obj["color"] as? NSNumber)?.intValue ?? 0,
                          strokeWidth: (obj["strokeWidth"] as? NSNumber)?.floatValue ?? 0)
    }

    var jsonString: String {
        let obj: [String: Any] = ["action": action, "x": x, "y": y, "color": color, "strokeWidth": strokeWidth]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}

/// 绘图同步管理器 (Android: service/DrawSyncManager.java)
/// 设备同步模式下通过 TCP 长连接与其他设备实时双向同步绘图事件。
final class LDrawSyncManager {
    enum SyncMode { case web, device }

    private var stream: LTcpStream?
    private var targetDevice: Device?
    private var connectedFlag = false
    private let writeLock = NSLock()
    private var reading = false

    var onConnected: ((Device) -> Void)?
    var onConnectFailed: ((Device, String) -> Void)?
    var onDisconnected: ((Device) -> Void)?
    /// 收到远端绘图事件
    var onRemoteDraw: ((LDrawEvent) -> Void)?
    /// 断连时的额外清理（接收端用于清理绘图页引用）
    var onDisconnectCallback: (() -> Void)?

    var isConnected: Bool { connectedFlag }
    var device: Device? { targetDevice }

    // MARK: - 发起方

    /// 连接目标设备并进入双向循环
    func connect(to device: Device, service: LANService?) {
        disconnect()
        targetDevice = device
        LThread.run { [weak self] in
            guard let self else { return }
            do {
                guard let from = service?.deviceManager.matchLocalDevice(for: device) else {
                    throw LSError.io("no local device")
                }
                let stream = try LTcpStream.connect(host: device.devIP, port: Int(device.devPort))
                try stream.writeInt(LConst.magicNum)
                try stream.writeInt(LCmd.newVersion4)
                var selfDevice = from
                selfDevice.devMode = LSelfDeviceType.value
                try stream.writeString(selfDevice.jsonString)
                self.writeLock.lock()
                try stream.writeInt(LCmd.fsDrawSyncRequest)
                try stream.writeString(LSettings.shared.devName)
                self.writeLock.unlock()

                let response = try stream.readInt()
                guard response == LCmd.fsDrawSyncAccept else {
                    stream.close()
                    LThread.main { self.onConnectFailed?(device, "对方拒绝了绘图同步请求") }
                    return
                }
                self.bind(stream: stream, device: device)
                LThread.main { self.onConnected?(device) }
                self.readLoop()
            } catch {
                self.cleanup()
                LThread.main { self.onConnectFailed?(device, "\(error)") }
            }
        }
    }

    /// 接收端绑定已有连接
    func bind(stream: LTcpStream, device: Device) {
        writeLock.lock()
        self.stream?.close()
        self.stream = stream
        targetDevice = device
        connectedFlag = true
        writeLock.unlock()
    }

    /// 发送接受响应（接收端调用，与后续写入共用同一把锁）
    func sendAccept() throws {
        guard let stream else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        try stream.writeInt(LCmd.fsDrawSyncAccept)
    }

    func sendReject() throws {
        guard let stream else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        try stream.writeInt(LCmd.fsDrawSyncReject)
    }

    // MARK: - 事件收发

    /// 发送本地绘图事件（JSON 原文，与网页端事件格式一致）
    func sendDrawEvent(json: String) {
        guard connectedFlag, let stream else { return }
        LThread.run { [weak self] in
            self?.writeCommand(cmd: LCmd.fsDraw, data: json, stream: stream)
        }
    }

    func sendDrawEvent(_ event: LDrawEvent) {
        sendDrawEvent(json: event.jsonString)
    }

    private func writeCommand(cmd: Int32, data: String, stream: LTcpStream) {
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try stream.writeInt(cmd)
            try stream.writeString(data)
        } catch {
            handleDisconnect()
        }
    }

    /// 双向读取循环，阻塞直到断开
    func readLoop() {
        writeLock.lock()
        guard connectedFlag, !reading, let stream = self.stream else { writeLock.unlock(); return }
        reading = true
        writeLock.unlock()
        do {
            while connectedFlag {
                let cmd = try stream.readInt()
                guard cmd == LCmd.fsDraw else { break }
                guard let json = try stream.readString(), let event = LDrawEvent.from(jsonString: json) else { continue }
                LThread.main { [weak self] in self?.onRemoteDraw?(event) }
            }
        } catch {
            LLog.debug("draw sync read loop ended: \(error)")
        }
        if connectedFlag {
            handleDisconnect()
        }
    }

    func disconnect() {
        let device = targetDevice
        let listener = onDisconnected
        cleanup()
        if let device {
            LThread.main { listener?(device) }
        }
    }

    private func handleDisconnect() {
        guard connectedFlag else { return }
        let device = targetDevice
        let listener = onDisconnected
        let callback = onDisconnectCallback
        cleanup()
        LThread.main {
            LANService.shared.showToast("绘图设备连接已断开")
            if let device { listener?(device) }
            callback?()
        }
    }

    private func cleanup() {
        writeLock.lock()
        connectedFlag = false
        reading = false
        stream?.close()
        stream = nil
        writeLock.unlock()
    }
}
