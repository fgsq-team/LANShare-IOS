import Foundation
import Combine
import Network
import UIKit

/// 网页服务桥接（由 Web/HttpServer 在启动时注册）
protocol LHttpServicing: AnyObject {
    func sendDeviceList()
    func sendMessageToWeb(_ text: String, devName: String, devMode: Int32, messageType: Int,
                          filePath: String, isLeft: Bool, isClip: Bool)
    func sendToDevice(_ text: String, device: Device, isClip: Bool)
    /// 绘图事件转发给网页端 (WSCmd.DRAW_EVENT)
    func sendDrawEvent(_ json: String)
    func sendClearDraw()
}

/// 待用户确认的接收请求 (Android: LCmd.SERVICE_IF_RECIVE_FILES + RecvFileCallback)
final class LPendingReceive {
    let count: Int
    let deviceName: String
    let totalSize: Int64
    private var completion: ((Bool) -> Void)?
    private let gate = NSLock()

    init(count: Int, deviceName: String, totalSize: Int64, completion: @escaping (Bool) -> Void) {
        self.count = count
        self.deviceName = deviceName
        self.totalSize = totalSize
        self.completion = completion
    }

    var sizeText: String { MessageFileContent.formatSize(totalSize) }

    func reply(_ isAgree: Bool) {
        gate.lock()
        let block = completion
        completion = nil
        gate.unlock()
        block?(isAgree)
    }
}

/// 待授权的网页客户端 (Android: LCmd.SERVICE_HTTP_NEW_CLIENT + String[]{token, ip, name})
final class LPendingWebClient {
    let token: String
    let ip: String
    let name: String

    init(token: String, ip: String, name: String) {
        self.token = token
        self.ip = ip
        self.name = name
    }
}

/// 局域网服务门面 (Android: service/LANService.java)
/// 承载设备发现、UDP/TCP 收发、消息列表与数据库；UI 通过 @Published 观察。
final class LANService: ObservableObject {
    static let shared = LANService()

    // MARK: - 管理器
    private(set) lazy var deviceManager = DeviceManager(service: self)
    private(set) lazy var fileSend = LFileSender(service: self)
    private(set) lazy var fileServer = LFileServer(service: self)
    private(set) lazy var udpServer = LUdpServer(deviceManager: deviceManager, service: self)
    private(set) lazy var tcpServer = LTcpServer(service: self)
    private(set) lazy var messageDB = LMessageDB()
    private(set) lazy var mediaIdPathDB = LMediaIdPathDB()
    private(set) lazy var tokenDB = LTokenDB()
    private(set) lazy var fileShareDB = LFileShareDB()
    private(set) lazy var fileSyncDB = LFileSyncDB()
    let drawSyncManager = LDrawSyncManager()

    /// 内置网页服务，由 Web 层注册
    var httpServer: LHttpServicing?

    // MARK: - 可观察状态
    @Published var devices: [Device] = []
    @Published var messages: [MessageContent] = []
    @Published var pendingReceive: LPendingReceive?
    @Published var pendingDrawSync: LPendingDrawSync?
    @Published var pendingWebClient: LPendingWebClient?
    @Published var toastText: String = ""
    @Published var toastId = 0
    @Published var isRunning = false
    /// 还有更早的历史消息可翻 (Android: FragmentChat pageCount * pageSize < 总数)
    @Published private(set) var hasOlderMessages = false
    @Published private(set) var isLoadingOlderMessages = false

    private var loadedIds = Set<String>()
    private var messagePageNum = 0
    private var messageTotalPages = 1
    private var lastMessageTime: Int64 = 0

    // MARK: - 网络变化监听
    /// 换网后 BSD 监听 socket 会失效，而 start() 被 isRunning 守卫跳过，只能靠重绑自愈
    private var pathMonitor: NWPathMonitor?
    private let netQueue = DispatchQueue(label: "fgsqw.lanshare.network")
    private var netSignature = ""

    var messageKey: String { LSettings.shared.messageKey }
    var devName: String { LSettings.shared.devName }

    private init() {}

    // MARK: - 生命周期

    /// 对应 onCreate：初始化数据 → 启动服务 → 广播上线 → 扫描
    func start() {
        guard !isRunning else { return }
        isRunning = true
        ResumeStore.cleanupExpired()
        initData()
        netSignature = Self.networkSignature()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            // 与 Android NetWorkReceiver 一致：等 1s 让新网卡地址就绪再比对
            self?.netQueue.asyncAfter(deadline: .now() + 1) { self?.checkNetworkChange() }
        }
        monitor.start(queue: netQueue)
        pathMonitor = monitor
        udpServer.start()
        tcpServer.start()
        // 网页路由始终注册，是否放行由 TcpServer 的 webService 开关决定，运行期改开关无需重启
        LWebServer.shared.start(service: self)
        deviceManager.notifyAllDevicesOnline()
        deviceManager.startScanning()
        deviceManager.onDevicesChanged = { [weak self] in
            guard let self else { return }
            self.devices = self.deviceManager.allDeviceList()
                .sorted { $0.devName.localizedCompare($1.devName) == .orderedAscending }
        }
        reloadMessages()
        LLog.debug("LANService started, \(devices.count) devices")
    }

    /// 对应 onDestroy
    func stop() {
        guard isRunning else { return }
        isRunning = false
        pathMonitor?.cancel()
        pathMonitor = nil
        deviceManager.setRunning(false)
        tcpServer.stop()
        udpServer.stop()
        LWebServer.shared.stop()
        deviceManager.notifyAllDevicesOffline()
    }

    /// 对应 initData：刷新本机各网卡身份
    func initData() {
        deviceManager.refreshLocalDevices()
        devices = deviceManager.allDeviceList()
    }

    // MARK: - 网络变化自愈

    /// 本机 IPv4 网段签名；换网（IP/掩码变化）时签名改变
    private static func networkSignature() -> String {
        NetUtils.netInfoList().map { "\($0.ip)/\($0.mask)" }.sorted().joined(separator: ",")
    }

    /// 比对网段签名，变化则重绑监听 socket。由 NWPathMonitor、扫描循环、回到前台共同触发，
    /// 签名去重保证只重绑一次；串行队列避免并发重绑。
    func checkNetworkChange() {
        let sig = Self.networkSignature()
        netQueue.async { [weak self] in
            guard let self else { return }
            guard sig != self.netSignature else { return }
            self.netSignature = sig
            guard !sig.isEmpty, self.isRunning else { return }
            self.rebindServers()
        }
    }

    /// 等价于用户手动重启 App 的网络部分：重绑 UDP/TCP 监听、刷新身份、剔除跨网段设备、重新广播上线
    private func rebindServers() {
        LLog.debug("network changed, rebinding udp/tcp listeners")
        deviceManager.refreshLocalDevices()
        deviceManager.evictOffSubnet()
        udpServer.start()
        tcpServer.stop()
        tcpServer.start()
        deviceManager.notifyAllDevicesOnline()
    }

    // MARK: - 消息

    /// 对应 addMessage：写入聊天列表与数据库
    func addMessage(_ content: MessageContent) {
        // 时间分隔必须先入列，否则它会落在刚追加的消息下面 (Android: FragmentChat.addMessage)
        checkAndAddChatTime(content.id)
        messages.append(content)
        loadedIds.insert(content.id)
        if LSettings.shared.saveMessage {
            messageDB.add(content)
        }
        // 网页端同步（Android 由 UI 转发到 WebSocket）
        onMessageAdded?(content)
    }

    /// 新消息加入聊天列表的回调，Web 层用于向已连接的网页客户端广播
    var onMessageAdded: ((MessageContent) -> Void)?

    /// 接收文本消息（UDP 1004/1005 与 TCP FS_MESSAGE 共用）
    func receiveTextMessage(_ text: String, from device: Device, isClip: Bool) {
        if isClip {
            UIPasteboard.general.string = text
            showToast("已复制到剪贴板")
        }
        let content = MessageTextContent()
        content.content = text
        content.isLeft = true
        content.userName = device.devName
        content.devMode = device.devMode
        content.status = MessageStatus.success
        content.isClip = isClip
        addMessage(content)
    }

    func receiveMessage(_ gps: MessageGPSContent) {
        addMessage(gps)
    }

    /// 发送文本消息给某个设备（nil = 所有设备）
    /// isClip 为 true 时写入对方剪贴板 (Android: 长按发送键)
    func sendTextMessage(_ text: String, to device: Device?, isClip: Bool = false) {
        let content = MessageTextContent()
        content.content = text
        content.isLeft = false
        content.isClip = isClip
        content.userName = devName
        content.toUser = device?.devName ?? LConst.allDevicesKey
        content.status = MessageStatus.success
        addMessage(content)
        udpServer.broadcastMessage(to: device, text: text, isClip: isClip)
    }

    /// 发送剪贴板内容
    func sendClipboard(to device: Device?) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            showToast("剪贴板为空")
            return
        }
        let content = MessageTextContent()
        content.content = text
        content.isLeft = false
        content.isClip = true
        content.userName = devName
        content.status = MessageStatus.success
        addMessage(content)
        udpServer.broadcastMessage(to: device, text: text, isClip: true)
    }

    func sendGPS(_ gps: MessageGPSContent, to device: Device?) {
        gps.isLeft = false
        gps.userName = devName
        gps.status = MessageStatus.success
        addMessage(gps)
        udpServer.broadcastGPS(gps, to: device)
    }

    /// 对应 checkAndAddChatTime：超过 5 分钟插入时间分隔
    func checkAndAddChatTime(_ bindId: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        guard now - lastMessageTime > 5 * 60 * 1000 else { return }
        // bindId 要进 init：分隔条的 id 是 "time_" + bindId，漏掉它会让所有分隔条同 id，
        // ForEach 直接不渲染，数据库里也只留最后一条 (Android: 每条用新 UUID)
        let timeContent = MessageTimeContent(bindId: bindId)
        messages.append(timeContent)
        if LSettings.shared.saveMessage {
            messageDB.add(timeContent)
        }
        lastMessageTime = Int64(timeContent.createTime.timeIntervalSince1970 * 1000)
    }

    /// 启动时只载入最近一页 (Android: FragmentChat.loadData 首次取 pageCount=0)
    func reloadMessages() {
        guard LSettings.shared.saveMessage else { return }
        let (list, total) = messageDB.query(pageNum: 0)
        messages = list
        loadedIds = Set(list.map { $0.id })
        messagePageNum = 0
        messageTotalPages = max(total, 1)
        hasOlderMessages = messagePageNum < messageTotalPages - 1
        lastMessageTime = list.last.map { Int64($0.createTime.timeIntervalSince1970 * 1000) } ?? 0
    }

    /// 滚动到顶部时取更早的一页；added 表示本次是否真的插入了记录
    func loadOlderMessages(_ completion: ((Bool) -> Void)? = nil) {
        guard LSettings.shared.saveMessage, hasOlderMessages, !isLoadingOlderMessages else {
            completion?(false)
            return
        }
        isLoadingOlderMessages = true
        let next = messagePageNum + 1
        LThread.run { [weak self] in
            guard let self else { return }
            let (list, total) = self.messageDB.query(pageNum: next)
            LThread.main {
                self.messageTotalPages = max(total, 1)
                self.messagePageNum = next
                self.isLoadingOlderMessages = false
                if list.isEmpty {
                    // 删除记录后总页数会虚高，取到空页就当翻到头
                    self.messageTotalPages = self.messagePageNum + 1
                    self.hasOlderMessages = false
                    completion?(false)
                    return
                }
                let head = list.filter { !self.loadedIds.contains($0.id) }
                self.loadedIds.formUnion(list.map { $0.id })
                if !head.isEmpty { self.messages.insert(contentsOf: head, at: 0) }
                self.hasOlderMessages = self.messagePageNum < self.messageTotalPages - 1
                completion?(!head.isEmpty)
            }
        }
    }

    func deleteMessages(_ contents: [MessageContent]) {
        let ids = Set(contents.map { $0.id })
        messages.removeAll { ids.contains($0.id) }
        contents.forEach { loadedIds.remove($0.id) }
        messageDB.delete(ids: Array(ids))
    }

    func clearMessages() {
        messages.removeAll()
        loadedIds.removeAll()
        messageDB.deleteAll()
        messagePageNum = 0
        messageTotalPages = 1
        hasOlderMessages = false
    }

    /// 按类型清理消息 (Android: 清理消息 → 文本/文件/已删除文件)
    func clearMessages(ofTypes types: [Int]) {
        let targets = messages.filter { types.contains($0.messageType) }
        deleteMessages(targets)
    }

    /// 清理数据库里文件已不存在的消息 (Android: 已删除文件)
    func clearMissingFileMessages() {
        let targets = messages.compactMap { $0 as? MessageFileContent }
            .filter { !$0.path.isEmpty && !FileManager.default.fileExists(atPath: $0.path) }
        deleteMessages(targets)
    }

    // MARK: - 文件

    /// 发送一组文件给目标设备（nil = 所有在线设备）
    func sendFiles(_ files: [MessageFileContent], to device: Device?) {
        let targets = device.map { [$0] } ?? deviceManager.targets(for: nil)
        guard !targets.isEmpty else {
            showToast("没有可发送的设备")
            for file in files {
                file.status = MessageStatus.error
                file.stateMessage = "发送失败"
            }
            return
        }
        for target in targets where target.isWeb {
            showToast("网页端不支持接收文件")
        }
        let receivers = targets.filter { !$0.isWeb }
        guard !receivers.isEmpty else { return }
        for file in files {
            file.status = MessageStatus.inProgress
            file.progress = 0
            file.isTransfer = true
        }
        for target in receivers {
            // 每个目标一份独立副本，避免 fileId/进度互相覆盖 (Android: mUtil.deepCopyList)
            let copies = files.map { $0.deepCopy() }
            registerOutgoing(copies)
            fileSend.send(device: target, files: copies)
        }
    }

    private func registerOutgoing(_ files: [MessageFileContent]) {
        guard let first = files.first else { return }
        checkAndAddChatTime(first.id)
        for file in files where !loadedIds.contains(file.id) {
            messages.append(file)
            loadedIds.insert(file.id)
        }
    }

    // MARK: - 传输进度 (Android: sendShowProgressMeg / sendProgressMeg / sendCloseProgressMeg)

    func showProgress(_ files: [MessageFileContent]) {
        LThread.main { [weak self] in
            guard let self else { return }
            if let first = files.first { self.checkAndAddChatTime(first.id) }
            for file in files where !self.loadedIds.contains(file.id) {
                self.messages.append(file)
                self.loadedIds.insert(file.id)
            }
            if LSettings.shared.saveMessage {
                self.messageDB.addOrUpdateList(files)
            }
        }
    }

    func progressUpdate(_ file: MessageFileContent) {
        file.status = MessageStatus.inProgress
    }

    func closeProgress(_ file: MessageFileContent) {
        if LSettings.shared.saveMessage {
            messageDB.update(file)
        }
        // 接收成功的媒体写入相册 (Android: save_to_gallery)
        if file.isLeft, file.isSuccess, let media = file as? MessageMediaContent,
           LSettings.shared.saveToGallery, !media.path.isEmpty {
            MediaSaver.save(url: URL(fileURLWithPath: media.path), isVideo: media.isVideo)
        }
    }

    // MARK: - 确认对话框

    /// 对应 sendIfReceiveFilesMsg
    func requestReceiveApproval(files: [MessageFileContent], completion: @escaping (Bool) -> Void) {
        let total = files.reduce(Int64(0)) { $0 + $1.length }
        let pending = LPendingReceive(count: files.count, deviceName: files.first?.userName ?? "",
                                      totalSize: total) { isAgree in
            completion(isAgree)
        }
        LThread.main { [weak self] in
            self?.pendingReceive = pending
        }
    }

    func resolveReceiveApproval(isAgree: Bool) {
        let pending = pendingReceive
        pendingReceive = nil
        pending?.reply(isAgree)
    }

    /// 对应 SERVICE_HTTP_NEW_CLIENT → FragmentChat.newHttpClient；网页端轮询 /checkPass 得知结果
    func requestWebClientApproval(token: String, ip: String, name: String) {
        LThread.main { [weak self] in
            guard let self else { return }
            if let current = self.pendingWebClient, current.token == token { return }
            self.pendingWebClient = LPendingWebClient(token: token, ip: ip, name: name)
        }
    }

    func resolveWebClientApproval(isAgree: Bool) {
        let pending = pendingWebClient
        pendingWebClient = nil
        if isAgree, let token = pending?.token {
            tokenDB.setPass(token: token, pass: 1)
            showToast("已授权 \(pending?.name ?? "")")
        }
    }

    /// 绘图同步授权 (Android: BaseActivity.showDrawSyncConfirm)
    final class LPendingDrawSync {
        let requesterName: String
        var completion: ((Bool) -> Void)?
        init(requesterName: String) { self.requesterName = requesterName }
        func reply(_ accepted: Bool) {
            let block = completion
            completion = nil
            block?(accepted)
        }
    }

    func requestDrawSyncApproval(requesterName: String, completion: @escaping (Bool) -> Void) {
        let pending = LPendingDrawSync(requesterName: requesterName)
        pending.completion = completion
        LThread.main { [weak self] in
            self?.pendingDrawSync = pending
        }
    }

    func resolveDrawSync(accepted: Bool) {
        let pending = pendingDrawSync
        pendingDrawSync = nil
        pending?.reply(accepted)
    }

    func cancelDrawSyncApproval() {
        LThread.main { [weak self] in self?.pendingDrawSync = nil }
    }

    /// 接收端进入绘图页（由 UI 层注入实现）
    var openDrawingReceiverHandler: ((String, LDrawSyncManager) -> Void)?
    func openDrawingReceiver(deviceName: String, manager: LDrawSyncManager) {
        openDrawingReceiverHandler?(deviceName, manager)
    }

    /// 扫码页在配对成功后退出 (Android: DeviceQrCodeActivity.exitFlag)
    var onDeviceQrCodeScanned: (() -> Void)?
    func deviceQrCodeScanned() {
        LThread.main { [weak self] in self?.onDeviceQrCodeScanned?() }
    }

    /// 设备选择弹窗里点击设备后回调扫码等 UI 动作
    func makeQRContent() -> String {
        let ips = deviceManager.selfDevices.filter { $0.isIPv4 }.map { $0.devIP }.joined(separator: ",")
        let isIPv6 = deviceManager.selfDevices.contains { !$0.isIPv4 && !$0.devIP.isEmpty }
        let firstIPv6 = deviceManager.selfDevices.first { !$0.isIPv4 }?.devIP ?? ""
        let addr = isIPv6 && ips.isEmpty ? firstIPv6 : ips
        let mode = (!isIPv6 || !ips.isEmpty) ? "0" : "1"
        return "\(LConst.key)-\(mode)-\(addr)-\(LSettings.shared.tcpPort)"
    }

    func scanQR(_ content: String, completion: @escaping (Result<Device, Error>) -> Void) {
        fileSend.addDeviceByQR(qr: content, completion: completion)
    }

    // MARK: - 网页请求

    var handleWebRequestHandler: ((LTcpStream, String) -> Void)?
    func handleWebRequest(stream: LTcpStream, head: String) {
        guard let handler = handleWebRequestHandler else {
            stream.close()
            return
        }
        handler(stream, head)
    }

    // MARK: - 提示

    func showToast(_ text: String) {
        LThread.main { [weak self] in
            self?.toastText = text
            self?.toastId += 1
        }
    }
}
