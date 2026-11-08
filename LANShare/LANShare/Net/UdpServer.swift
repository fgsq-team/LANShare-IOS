import Foundation

/// UDP 接收与消息广播 (Android: service/manager/UdpServerManager.java)
final class LUdpServer {
    private var channel: LUdpChannel?
    private var running = false
    private let deviceManager: DeviceManager
    weak var service: LANService?

    init(deviceManager: DeviceManager, service: LANService?) {
        self.deviceManager = deviceManager
        self.service = service
    }

    /// 绑定 UDP 端口并启动接收循环；端口变更后可重新调用
    func start() {
        stop()
        let port = LSettings.shared.udpPort
        running = true
        do {
            let ch = try LUdpChannel(bindPort: port)
            channel = ch
        } catch {
            LLog.error("udp bind \(port) failed: \(error)")
            return
        }
        LThread.run { [weak self] in
            guard let self, let ch = self.channel else { return }
            while self.running {
                do {
                    let (packet, fromIP, _) = try ch.receive(maxSize: 4096)
                    LThread.run {
                        self.handleUdp(packet, fromIP: fromIP)
                    }
                } catch LSError.timeout {
                    continue
                } catch {
                    if self.running { LLog.debug("udp recv stopped: \(error)") }
                    return
                }
            }
        }
    }

    func stop() {
        running = false
        channel?.close()
        channel = nil
    }

    /// 对应 handleUdp：校验 magic，解混淆，读取设备信息
    private func handleUdp(_ packet: [UInt8], fromIP: String) {
        guard packet.count > 4, LByte.bytesToInt(packet, 0) == LConst.magicNum else { return }
        let payload = Array(packet.dropFirst(4))
        let dec = DataDec(payload)
        dec.decAllData()
        let cmd = dec.cmd
        let devPort = dec.getInt()
        let devIp = dec.getString()
        let devName = dec.getString()
        let devMode = dec.getInt()
        var uniqueUUid = dec.getString()
        var dataVersion = dec.getInt()
        let batteryLevel = dec.getInt()
        let chargeStatus = dec.getByte()

        // 排除自己发出的包
        let myIP = devIp.isEmpty ? fromIP : devIp
        if deviceManager.selfDevices.contains(where: { $0.devIP == myIP }) { return }

        // uuid 后缀携带真实协议版本："uuid-5"
        if uniqueUUid.contains("-") {
            let parts = uniqueUUid.split(separator: "-")
            if parts.count == 2, let v = Int32(parts[1]) {
                dataVersion = v
                uniqueUUid = String(parts[0])
            }
        }

        let device = Device(devName: devName, devIP: myIP, devPort: devPort)
        device.devMode = devMode
        device.uniqueUUid = uniqueUUid
        device.dataVersion = dataVersion
        device.setTime = Int64(Date().timeIntervalSince1970 * 1000)
        device.batteryLevel = batteryLevel
        device.chargeStatus = chargeStatus
        device.isIPv4 = myIP.contains(".") && !myIP.contains(":")
        deviceManager.addDevice(device)
        handleUdpCmd(device, cmd: cmd, dec: dec)
    }

    private func handleUdpCmd(_ device: Device, cmd: Int32, dec: DataDec) {
        switch cmd {
        case LCmd.udpGetDevices:
            // 收到扫描请求 → 单播回复自己在线
            deviceManager.noticeDeviceState(toIP: device.devIP, isBroadcast: false, isOnLine: true)
        case LCmd.udpDevicesOffLine:
            if device.canRemove {
                deviceManager.removeDevice(device.address)
            }
        case LCmd.udpDevicesMessage, LCmd.udpDevicesMessageToClipboard:
            let messageEnc = dec.getString()
            _ = dec.getString() // packageName：仅 Android 三方广播导出使用
            let isClip = cmd == LCmd.udpDevicesMessageToClipboard
            guard let text = LCrypto.decryptMessage(messageEnc, key: service?.messageKey ?? "") else {
                LLog.error("message decrypt failed")
                service?.showToast("消息解密失败")
                return
            }
            service?.receiveTextMessage(text, from: device, isClip: isClip)
        case LCmd.udpSendMap:
            let json = dec.getString()
            if let gps = MessageGPSContent.from(jsonString: json) {
                gps.isLeft = true
                gps.userName = device.devName
                gps.devMode = device.devMode
                gps.status = MessageStatus.success
                service?.receiveMessage(gps)
            }
        default:
            break
        }
    }

    /// 发送文本消息（对应 broadcastMessage）
    /// - Parameter toDevice: nil 表示所有在线设备
    func broadcastMessage(to toDevice: Device?, text: String, isClip: Bool, shareWS: Bool = true) {
        guard let message = LCrypto.encryptMessage(text, key: service?.messageKey ?? "") else {
            service?.showToast("消息加密失败")
            return
        }
        let targets: [Device]
        if let toDevice {
            targets = [toDevice]
        } else {
            targets = deviceManager.deviceList()
        }
        if shareWS {
            service?.httpServer?.sendMessageToWeb(text, devName: isClip ? "" : LConst.allDevicesKey,
                                                  devMode: -1, messageType: 0, filePath: "", isLeft: false, isClip: isClip)
        }
        LThread.run { [weak self] in
            guard let self else { return }
            for dev in targets {
                if dev.isWeb {
                    self.service?.httpServer?.sendToDevice(text, device: dev, isClip: isClip)
                    continue
                }
                // 长文本走 TCP FS_MESSAGE（V4/V5）
                if text.count > LConst.udpMessageCharLimit || !dev.isIPv4 {
                    if dev.dataVersion >= LVersion.dataVersion4 {
                        self.service?.fileSend.sendTCPMessage(to: dev, encrypted: message, isClip: isClip)
                    }
                    continue
                }
                let size = 1024 + message.utf8.count
                let enc: DataEnc
                if let from = self.deviceManager.matchLocalDevice(for: dev) {
                    enc = self.deviceManager.makeUdpBody(from: from, size: size)
                } else {
                    enc = self.deviceManager.makeUdpBody(from: Device(devName: self.deviceManager.devName,
                                                                      devIP: "", devPort: Int32(LSettings.shared.tcpPort)),
                                                        size: size)
                }
                _ = enc.setCmd(isClip ? LCmd.udpDevicesMessageToClipboard : LCmd.udpDevicesMessage)
                _ = enc.putString(message)
                _ = enc.putString("")
                if let ch = try? LUdpChannel.sending(localIP: nil) {
                    try? ch.send(DeviceManager.packet(from: enc), to: dev.devIP, port: LSettings.shared.udpPort)
                    ch.close()
                }
            }
        }
    }

    /// 位置消息（UDP_SEND_MAP）
    func broadcastGPS(_ gps: MessageGPSContent, to toDevice: Device?) {
        let targets = toDevice.map { [$0] } ?? deviceManager.deviceList()
        LThread.run { [weak self] in
            guard let self else { return }
            for dev in targets where dev.isIPv4 && !dev.isWeb {
                guard let from = self.deviceManager.matchLocalDevice(for: dev) else { continue }
                let enc = self.deviceManager.makeUdpBody(from: from, size: 1024)
                _ = enc.setCmd(LCmd.udpSendMap)
                _ = enc.putString(gps.jsonString)
                if let ch = try? LUdpChannel.sending(localIP: from.devIP) {
                    try? ch.send(DeviceManager.packet(from: enc), to: dev.devIP, port: LSettings.shared.udpPort)
                    ch.close()
                }
            }
        }
    }
}
