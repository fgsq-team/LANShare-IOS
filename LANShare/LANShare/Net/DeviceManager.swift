import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// 电量读取 (Android: utils/BatteryUtil.java)
enum LBattery {
    /// (level 0-100 / -1, chargeStatus 1=充电或充满 0=未充电)
    static func read() -> (level: Int32, charging: UInt8) {
        #if canImport(UIKit)
        let device = UIDevice.current
        let wasEnabled = device.isBatteryMonitoringEnabled
        if !wasEnabled { device.isBatteryMonitoringEnabled = true }
        defer { if !wasEnabled { device.isBatteryMonitoringEnabled = false } }
        let level = device.batteryLevel
        let charging: UInt8
        switch device.batteryState {
        case .charging, .full: charging = 1
        case .unplugged: charging = 0
        default: charging = UInt8(truncatingIfNeeded: -1)
        }
        if level < 0 { return (-1, charging == 255 ? charging : 0) }
        return (Int32(level * 100), charging)
        #else
        return (-1, 0)
        #endif
    }
}

/// 在线设备管理与定时广播 (Android: service/manager/DeviceManager.java)
final class DeviceManager {
    /// 键为 "IP:Port"
    private(set) var onLineDevices: [String: Device] = [:]
    /// 网页端设备
    var onLineWebDevices: [String: Device] = [:]
    /// 本机各网卡对应的设备身份
    private(set) var localDevices: [Device] = []
    /// 已授权/手动添加的设备（不参与超时剔除）
    private var pinnedUuids = Set<String>()

    private let gate = NSLock()
    private var running = true
    weak var service: LANService?

    var onDevicesChanged: (() -> Void)?

    init(service: LANService?) {
        self.service = service
    }

    var devName: String { LSettings.shared.devName }

    func setRunning(_ value: Bool) {
        gate.lock()
        running = value
        gate.unlock()
    }

    var isRunning: Bool {
        gate.lock()
        defer { gate.unlock() }
        return running
    }

    // MARK: - 设备表

    func addDevice(_ device: Device) {
        gate.lock()
        onLineDevices[device.address] = device
        gate.unlock()
        LLog.debug("device online \(device.devName) \(device.address) v\(device.dataVersion)")
        notifyChange()
        service?.httpServer?.sendDeviceList()
    }

    func removeDevice(_ address: String) {
        gate.lock()
        let removed = onLineDevices.removeValue(forKey: address)
        gate.unlock()
        if removed != nil {
            LLog.debug("device offline \(address)")
            notifyChange()
            service?.httpServer?.sendDeviceList()
        }
    }

    func deviceList() -> [Device] {
        gate.lock()
        defer { gate.unlock() }
        return Array(onLineDevices.values)
    }

    /// 本机设备 + 网页端设备，供设备选择与广播使用
    func allDeviceList() -> [Device] {
        gate.lock()
        defer { gate.unlock() }
        return Array(onLineDevices.values) + Array(onLineWebDevices.values)
    }

    /// 网页端上线 (Android: LHttpServer 里 onLineWebDevices.put)
    func addWebDevice(_ device: Device) {
        gate.lock()
        onLineWebDevices[device.address] = device
        gate.unlock()
        LLog.debug("web device online \(device.devName) \(device.address)")
        notifyChange()
    }

    func removeWebDevice(address: String) {
        gate.lock()
        let removed = onLineWebDevices.removeValue(forKey: address)
        gate.unlock()
        if removed != nil {
            LLog.debug("web device offline \(address)")
            notifyChange()
        }
    }

    func device(for address: String) -> Device? {
        gate.lock()
        defer { gate.unlock() }
        return onLineDevices[address] ?? onLineWebDevices[address]
    }

    /// 供发送流程使用：address 为空或 "所有设备" 时返回全部
    func targets(for address: String?) -> [Device] {
        gate.lock()
        let all = Array(onLineDevices.values) + Array(onLineWebDevices.values)
        let webOnly = onLineWebDevices
        gate.unlock()
        guard let address, !address.isEmpty else { return all }
        if address == LConst.allDevicesKey { return all }
        if let one = all.first(where: { $0.address == address }) { return [one] }
        _ = webOnly
        return all
    }

    func pin(uuid: String) {
        gate.lock()
        pinnedUuids.insert(uuid)
        gate.unlock()
    }

    private func notifyChange() {
        LThread.main { [weak self] in
            self?.onDevicesChanged?()
        }
    }

    // MARK: - 本机设备

    /// 对应 getSelfDevices()：按网卡生成身份，dataVersion 取当前协议版本
    func refreshLocalDevices() {
        let battery = LBattery.read()
        var devices: [Device] = []
        for info in NetUtils.netInfoList() {
            let d = Device(devName: devName, devIP: info.ip, devPort: Int32(LSettings.shared.tcpPort))
            d.devNetMask = info.mask
            d.devBrotIP = info.brodIp
            d.interfaceName = info.interfaceName
            d.uniqueUUid = LSettings.shared.uniqueUUid
            d.devMode = LSelfDeviceType.value
            d.dataVersion = Int32(LConst.dataVersion)
            d.isIPv4 = !info.isIPV6
            d.batteryLevel = battery.level
            d.chargeStatus = battery.charging
            devices.append(d)
        }
        gate.lock()
        localDevices = devices
        gate.unlock()
    }

    var selfDevices: [Device] {
        gate.lock()
        defer { gate.unlock() }
        return localDevices
    }

    /// 本机 IP 列表，用于丢弃自己发出的广播包
    private var localIPSet: Set<String> {
        Set(NetUtils.localIPv4s())
    }

    /// 对应 DeviceManager.getDevice(device)：同网段的本机身份
    func matchLocalDevice(for device: Device) -> Device? {
        gate.lock()
        let locals = localDevices
        gate.unlock()
        for local in locals {
            if !device.isIPv4 || NetUtils.subNet(device.devIP, local.devIP, local.devNetMask) {
                return local
            }
        }
        return locals.first
    }

    // MARK: - 包构造 (Android: makeDataEncUdp)

    /// UDP 包体：port,ip,name,mode,uuid-version,legacyVersion(3),battery,charge
    /// TCP 扫码配对回包用 makeDataEncCustomBuffer，其 legacyVersion 位置写当前版本
    func makeUdpBody(from device: Device, size: Int, announceVersion: Int32 = Int32(LVersion.dataVersion3)) -> DataEnc {
        let enc = DataEnc(size: size)
        _ = enc.putInt(device.devPort)
        _ = enc.putString(device.devIP)
        _ = enc.putString(device.devName)
        _ = enc.putInt(device.devMode)
        _ = enc.putString("\(device.uniqueUUid)-\(LConst.dataVersion)")
        _ = enc.putInt(announceVersion)
        _ = enc.putInt(device.batteryLevel)
        _ = enc.putByte(device.chargeStatus)
        return enc
    }

    /// 对应 UDPTools.sendData：magic + 混淆后的 DataEnc
    static func packet(from enc: DataEnc) -> [UInt8] {
        var magic = [UInt8](repeating: 0, count: 4)
        magic.withUnsafeMutableBufferPointer { LByte.intToBytes(LConst.magicNum, $0.baseAddress!, 0) }
        var out = magic
        out.append(contentsOf: enc.encData())
        return out
    }

    // MARK: - 扫描循环 (Android: scanDevices)

    func startScanning() {
        LThread.run { [weak self] in
            guard let self else { return }
            while self.isRunning {
                self.refreshLocalDevices()
                self.service?.checkNetworkChange()
                for local in self.selfDevices {
                    if !local.devBrotIP.isEmpty {
                        self.broadcast(announce: local, cmd: LCmd.udpGetDevices)
                    }
                }
                self.evictStale()
                LThread.sleep(seconds: LConst.scanInterval)
            }
            LLog.debug("scan loop stopped")
        }
    }

    private func broadcast(announce device: Device, cmd: Int32) {
        let enc = makeUdpBody(from: device, size: 1024)
        _ = enc.setCmd(cmd)
        let packet = DeviceManager.packet(from: enc)
        guard let channel = try? LUdpChannel.sending(localIP: device.devIP) else { return }
        defer { channel.close() }
        do {
            try channel.send(packet, to: device.devBrotIP, port: LSettings.shared.udpPort)
        } catch {
            // 部分网络不允许子网定向广播，退回全局广播
            try? channel.send(packet, to: "255.255.255.255", port: LSettings.shared.udpPort)
        }
    }

    private func evictStale() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var expired: [String] = []
        gate.lock()
        for (key, device) in onLineDevices {
            guard device.canRemove else { continue }
            if now - device.setTime > LConst.deviceTimeoutMs { expired.append(key) }
        }
        gate.unlock()
        for key in expired { removeDevice(key) }
    }

    /// 换网后剔除已不在任何本机网段的在线设备（保留扫码固定与 IPv6 设备），避免列表残留旧局域网设备
    func evictOffSubnet() {
        let locals = selfDevices
        gate.lock()
        let stale = onLineDevices.filter { _, device in
            guard device.canRemove, device.isIPv4 else { return false }
            return !locals.contains { NetUtils.subNet(device.devIP, $0.devIP, $0.devNetMask) }
        }.map { $0.key }
        gate.unlock()
        for key in stale { removeDevice(key) }
    }

    /// 对应 noticeDeviceStateByIp：单播回复或广播上下线
    func noticeDeviceState(toIP ip: String, isBroadcast: Bool, isOnLine: Bool) {
        LThread.run { [weak self] in
            guard let self else { return }
            let battery = LBattery.read()
            for local in self.selfDevices {
                if !isBroadcast, !NetUtils.subNet(ip, local.devIP, local.devNetMask) { continue }
                let target = Device(devName: local.devName, devIP: local.devIP, devPort: local.devPort)
                target.devNetMask = local.devNetMask
                target.devBrotIP = local.devBrotIP
                target.interfaceName = local.interfaceName
                target.uniqueUUid = local.uniqueUUid
                target.devMode = local.devMode
                target.dataVersion = local.dataVersion
                target.batteryLevel = battery.level
                target.chargeStatus = battery.charging
                let enc = self.makeUdpBody(from: target, size: 1024)
                _ = enc.setCmd(isOnLine ? LCmd.udpSetDevices : LCmd.udpDevicesOffLine)
                if let channel = try? LUdpChannel.sending(localIP: local.devIP) {
                    try? channel.send(DeviceManager.packet(from: enc), to: ip, port: LSettings.shared.udpPort)
                    channel.close()
                }
            }
        }
    }

    func notifyAllDevicesOnline() {
        for local in selfDevices {
            noticeDeviceState(toIP: local.devBrotIP, isBroadcast: true, isOnLine: true)
        }
    }

    func notifyAllDevicesOffline() {
        for local in selfDevices {
            noticeDeviceState(toIP: local.devBrotIP, isBroadcast: true, isOnLine: false)
        }
    }
}

/// iOS 端上报的设备类型 (Android 固定写 ANDROID)
enum LSelfDeviceType {
    static let value: Int32 = DevMode.ios.rawValue
}
