import Foundation
import UIKit

/// V4/V5 共用扩展功能 (Android: service/version/SyncFeatureHandler.java)
enum LSyncFeatureHandler {

    /// 接收 TCP 消息 (FS_MESSAGE)
    static func handleMessage(service: LANService?, device: Device, stream: LTcpStream) throws {
        let isClip = try stream.readBoolean()
        let encrypted = try stream.readString() ?? ""
        LLog.debug("tcp message: \(encrypted)")
        defer { stream.close() }
        let key = service?.messageKey ?? LSettings.shared.messageKey
        guard let message = LCrypto.decryptMessage(encrypted, key: key) else {
            LLog.error("message decrypt error")
            LThread.main { service?.showToast("消息解密失败") }
            return
        }
        let content = MessageTextContent()
        content.id = MessageContent.newId()
        content.content = message
        content.status = MessageStatus.success
        content.userName = device.devName
        content.isLeft = true
        content.isClip = isClip
        if isClip {
            UIPasteboard.general.string = message
            LThread.main { service?.showToast("已复制到剪贴板") }
        }
        LThread.main { service?.addMessage(content) }
    }

    /// 媒体同步协商 (FS_GET_NO_SYNC_MEDIA)：回复对方尚不存在的 mediaId
    static func handleMediaSync(service: LANService?, stream: LTcpStream) throws {
        defer { stream.close() }
        guard let json = try stream.readString(), let data = json.data(using: .utf8),
              let ids = try? JSONSerialization.jsonObject(with: data) as? [NSNumber] else { return }
        let missing = ids.filter { id in
            guard let db = service?.mediaIdPathDB else { return true }
            return !db.exists(id.int64Value)
        }
        let reply = try JSONSerialization.data(withJSONObject: missing)
        try stream.writeString(String(decoding: reply, as: UTF8.self))
    }

    /// 远程绘图同步请求 (FS_DRAW_SYNC_REQUEST)，长连接
    static func handleDrawSync(service: LANService?, device: Device, stream: LTcpStream) throws {
        let requesterName = try stream.readString() ?? device.devName
        let accepted = waitForApproval(service: service, requesterName: requesterName, timeout: 60)
        guard accepted else {
            try stream.writeInt(LCmd.fsDrawSyncReject)
            stream.close()
            return
        }
        let manager = service?.drawSyncManager ?? LDrawSyncManager()
        manager.bind(stream: stream, device: device)
        try manager.sendAccept()
        LThread.main {
            service?.openDrawingReceiver(deviceName: requesterName, manager: manager)
        }
        // 阻塞当前连接线程直到双向同步结束
        manager.readLoop()
        stream.close()
    }

    private static func waitForApproval(service: LANService?, requesterName: String, timeout: TimeInterval) -> Bool {
        guard let service else { return false }
        let lock = NSLock()
        var result: Bool?
        let deadline = Date().addingTimeInterval(timeout)
        service.requestDrawSyncApproval(requesterName: requesterName) { accepted in
            lock.lock()
            if result == nil { result = accepted }
            lock.unlock()
        }
        while Date() < deadline {
            lock.lock()
            let done = result != nil
            lock.unlock()
            if done { break }
            LThread.sleep(seconds: 0.2)
        }
        lock.lock()
        if result == nil {
            result = false
            service.cancelDrawSyncApproval()
        }
        let accepted = result ?? false
        lock.unlock()
        return accepted
    }
}
