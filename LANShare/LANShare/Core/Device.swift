import Foundation

/// 局域网设备 (Android: pojo/Device.java)
/// JSON 键名与 Android 端完全一致，保证握手互通
final class Device: Identifiable, Equatable, Hashable {
    var devName: String
    var devIP: String
    var devNetMask: String
    var devBrotIP: String
    var uniqueUUid: String
    var devPort: Int32
    var devMode: Int32
    var setTime: Int64
    var dataVersion: Int32
    var isIPv4: Bool
    var canRemove: Bool
    var interfaceName: String
    var batteryLevel: Int32
    var chargeStatus: UInt8

    /// 网页客户端的 WebSocket 连接（仅 devMode == web 时有值）
    weak var webSocket: AnyObject?

    init(devName: String = "", devIP: String = "", devPort: Int32 = 0) {
        self.devName = devName
        self.devIP = devIP
        self.devPort = devPort
        devNetMask = ""
        devBrotIP = ""
        uniqueUUid = ""
        devMode = DevMode.unknow.rawValue
        setTime = 0
        dataVersion = 0
        isIPv4 = true
        canRemove = true
        interfaceName = ""
        batteryLevel = -1
        chargeStatus = UInt8(truncatingIfNeeded: -1)
    }

    var id: String { address }
    var address: String { "\(devIP):\(devPort)" }
    var type: DevMode { DevMode(rawValue: devMode) ?? .unknow }
    var isWeb: Bool { devMode == DevMode.web.rawValue }

    /// 与 Android 一致：电量、充电状态
    var batteryText: String {
        batteryLevel < 0 ? "--" : "\(batteryLevel)%"
    }

    static func == (lhs: Device, rhs: Device) -> Bool {
        lhs.devIP == rhs.devIP && lhs.devPort == rhs.devPort && lhs.uniqueUUid == rhs.uniqueUUid
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(devIP)
        hasher.combine(devPort)
    }

    // MARK: - JSON (TCP 握手)

    /// 对应 Device.toJsonObject()，键名/顺序无关但必须全部存在
    var jsonObject: [String: Any] {
        [
            "devName": devName,
            "devIP": devIP,
            "devNetMask": devNetMask,
            "devBrotIP": devBrotIP,
            "uniqueUUid": uniqueUUid,
            "devPort": devPort,
            "devMode": devMode,
            "dataVersion": dataVersion,
            "isIPv4": isIPv4,
            "batteryLevel": batteryLevel,
            // Android 侧用 getByte("chargeStatus") 读取，超出 -128...127 会直接抛 JSONException
            // 并丢弃整条连接；本端未知状态存的是 0xFF，必须按有符号字节下发。
            "chargeStatus": Int(Int8(bitPattern: chargeStatus)),
        ]
    }

    var jsonString: String {
        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// 对应 Device.fromJsonString(JSONObject)：Android 侧用 getInteger/getByte 取值，
    /// 缺失字段会导致对端崩溃，因此这里对缺失值给安全默认。
    static func from(json: [String: Any]) -> Device {
        let d = Device()
        d.devName = json["devName"] as? String ?? ""
        d.devIP = json["devIP"] as? String ?? ""
        d.devNetMask = json["devNetMask"] as? String ?? ""
        d.devBrotIP = json["devBrotIP"] as? String ?? ""
        d.uniqueUUid = json["uniqueUUid"] as? String ?? ""
        d.devPort = int32(json["devPort"])
        d.devMode = int32(json["devMode"])
        d.dataVersion = int32(json["dataVersion"])
        d.isIPv4 = (json["isIPv4"] as? Bool) ?? true
        d.batteryLevel = int32(json["batteryLevel"])
        d.chargeStatus = UInt8(truncatingIfNeeded: Int(int32(json["chargeStatus"])))
        return d
    }

    static func from(jsonString: String) -> Device? {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return from(json: obj)
    }

    private static func int32(_ v: Any?) -> Int32 {
        if let n = v as? NSNumber { return Int32(truncatingIfNeeded: n.int64Value) }
        if let s = v as? String { return Int32(s) ?? 0 }
        return 0
    }
}
