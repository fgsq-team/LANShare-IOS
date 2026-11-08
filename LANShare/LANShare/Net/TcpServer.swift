import Foundation

/// TCP 服务器 (Android: service/manager/TcpServerManager.java)
/// 同一端口复用 LAN 二进制协议与 HTTP/WebSocket：按连接首 4 字节区分。
final class LTcpServer {
    weak var service: LANService?
    private var listener: LTcpListener?
    private var running = false

    init(service: LANService?) {
        self.service = service
    }

    func start() {
        guard !running else { return }
        running = true
        let port = LSettings.shared.tcpPort
        do {
            listener = try LTcpListener(port: port)
        } catch {
            LLog.error("启动 TCP 服务失败: \(error)")
            service?.showToast("启动 TCP 服务失败")
            running = false
            return
        }
        LThread.run { [weak self] in
            guard let self else { return }
            while self.running {
                guard let stream = try? self.listener?.accept() else {
                    if self.running { LThread.sleep(seconds: 1) }
                    continue
                }
                LThread.run { self.snoop(stream) }
            }
        }
    }

    func stop() {
        running = false
        listener?.close()
        listener = nil
    }

    /// 首 4 字节嗅探：LAN 魔法数 / HTTP 请求
    private func snoop(_ stream: LTcpStream) {
        do {
            let magic = try stream.readFully(4)
            let magicNum = LByte.bytesToInt(magic, 0)
            if magicNum == LConst.magicNum {
                handleTcp(stream: stream)
            } else if LSettings.shared.webService {
                let head = String(decoding: magic, as: UTF8.self).uppercased()
                if head.contains("GET") || head.contains("POST") {
                    service?.handleWebRequest(stream: stream, head: head)
                } else {
                    stream.close()
                }
            } else {
                stream.close()
            }
        } catch {
            LLog.debug("snoop failed: \(error)")
            stream.close()
        }
    }

    private func handleTcp(stream: LTcpStream) {
        let device: Device
        var legacyDec: DataDec?
        var legacyCmd: Int32 = 0
        do {
            let cmd = try stream.readInt()
            if cmd == LCmd.newVersion4 || cmd == LCmd.newVersion5 {
                let useV5 = cmd == LCmd.newVersion5
                let deviceJson = try stream.readString() ?? "{}"
                device = Device.from(jsonString: deviceJson) ?? Device()
                let minVersion: Int32 = useV5 ? Int32(LVersion.dataVersion5) : Int32(LVersion.dataVersion4)
                if device.dataVersion < minVersion {
                    device.dataVersion = minVersion
                }
                service?.deviceManager.addDevice(device)
                dispatchVersion(stream: stream, device: device, useV5: useV5)
            } else {
                // 旧版本 DataEnc 包：cmd(4) + count(4) + length(4) + 包体
                let rest = try stream.readFully(DataEnc.headerLen - 4)
                let header = magicless(cmd: cmd, rest: rest)
                let dec = DataDec(header)
                let length = Int(max(0, dec.length))
                let body = length > 0 ? try stream.readFully(length) : []
                legacyDec = DataDec(header + body)
                legacyCmd = cmd
                device = parseLegacyDevice(legacyDec!, peerIP: stream.remoteIP)
                service?.deviceManager.addDevice(device)
                handleLegacy(cmd: cmd, dec: legacyDec!, device: device, stream: stream)
            }
        } catch {
            LLog.debug("handleTcp error: \(error)")
            stream.close()
        }
    }

    private func magicless(cmd: Int32, rest: [UInt8]) -> [UInt8] {
        var head = [UInt8](repeating: 0, count: 4)
        head.withUnsafeMutableBufferPointer { LByte.intToBytes(cmd, $0.baseAddress!, 0) }
        return head + rest
    }

    /// 旧版本握手包里的设备块
    private func parseLegacyDevice(_ dec: DataDec, peerIP: String) -> Device {
        let devPort = dec.getInt()
        var devIp = dec.getString()
        if devIp.isEmpty { devIp = peerIP }
        let devName = dec.getString()
        let devMode = dec.getInt()
        var uuid = dec.getString()
        if uuid.contains("-") {
            uuid = String(uuid.split(separator: "-").first ?? Substring(uuid))
        }
        let dataVersion = dec.getInt()
        let battery = dec.getInt()
        let charge = dec.getByte()
        let existing = service?.deviceManager.device(for: "\(devIp):\(devPort)")
        let device = existing ?? Device()
        device.devName = devName
        device.devIP = devIp
        device.devPort = devPort
        device.uniqueUUid = uuid
        device.devMode = devMode
        device.setTime = Int64(Date().timeIntervalSince1970 * 1000)
        device.dataVersion = dataVersion
        device.batteryLevel = battery
        device.chargeStatus = charge
        return device
    }

    /// V4/V5 命令分发（与 Android 相同：交接给文件服务器）
    private func dispatchVersion(stream: LTcpStream, device: Device, useV5: Bool) {
        service?.fileServer.handleVersion(device: device, stream: stream, useV5: useV5)
    }

    // MARK: - 旧版本(< V4)命令

    private func handleLegacy(cmd: Int32, dec: DataDec, device: Device, stream: LTcpStream) {
        guard let service else {
            stream.close()
            return
        }
        if device.dataVersion >= Int32(LVersion.dataVersion4) {
            LLog.debug("不支持的版本: \(device.dataVersion)")
            stream.close()
            return
        }
        switch cmd {
        case LCmd.fsAddDevice:
            fsAddDevice(dec: dec, device: device, stream: stream, service: service)
        case LCmd.fsMessage:
            let encrypted = dec.getString()
            let message = LCrypto.decryptMessage(encrypted, key: service.messageKey)
            if let message {
                let content = MessageTextContent()
                content.id = MessageContent.newId()
                content.content = message
                content.status = MessageStatus.success
                content.userName = device.devName
                content.isLeft = true
                LThread.main { service.addMessage(content) }
            } else {
                LThread.main { service.showToast("消息解密失败") }
            }
            stream.close()
        case LCmd.fsShareFile, LCmd.fsGetNoSyncMedia, LCmd.fsUpdateApps, LCmd.fsGetApps:
            // 旧版本文件/应用同步链仅在 V4/V5 保留；对端为 V4+ 时走 dispatchVersion
            LLog.debug("legacy cmd \(cmd) not supported by iOS client")
            stream.close()
        default:
            stream.close()
        }
    }

    /// 扫码配对的接收端 (旧版本 FS_ADD_DEVICE)
    private func fsAddDevice(dec: DataDec, device: Device, stream: LTcpStream, service: LANService) {
        let isIPv6 = dec.getBool()
        device.isIPv4 = !isIPv6
        device.canRemove = false
        service.deviceManager.addDevice(device)

        var local: Device?
        if isIPv6 {
            local = service.deviceManager.selfDevices.first { !$0.isIPv4 } ?? service.deviceManager.selfDevices.first
        } else {
            local = service.deviceManager.localDevices.first {
                NetUtils.subNet($0.devIP, device.devIP, $0.devNetMask)
            }
        }
        guard let local else {
            LThread.main { service.showToast("添加失败：设备不在同一局域网") }
            stream.close()
            return
        }
        var selfDevice = local
        selfDevice.devMode = LSelfDeviceType.value
        let enc = service.deviceManager.makeUdpBody(from: selfDevice, size: 1024,
                                                    announceVersion: Int32(LConst.dataVersion))
        _ = enc.setCmd(LCmd.fsAddDevice)
        _ = enc.putBool(isIPv6)
        do {
            try stream.write(enc.getData())
            LThread.sleep(seconds: 0.2)
            LThread.main { service.showToast("已添加设备 \(device.devName)") }
        } catch {
            LLog.debug("add device reply failed: \(error)")
        }
        stream.close()
        service.deviceQrCodeScanned()
    }
}
