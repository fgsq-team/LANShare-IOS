import Foundation
import Combine

/// 网页端静态资源 (Android: lanService.getAssets().open("web/..."))
enum LWebResources {
    /// web.bundle 目录；若同步文件夹被展平则回退到 Bundle 根按文件名查找
    private static let root: URL? = {
        if let dir = Bundle.main.url(forResource: "web", withExtension: "bundle"),
           FileManager.default.fileExists(atPath: dir.appendingPathComponent("lanshare.html").path) {
            return dir
        }
        return nil
    }()

    /// name 形如 "web/css/lanshare.css"
    static func data(for name: String) -> Data? {
        guard let relative = sanitized(name) else { return nil }
        if let root {
            let candidate = root.appendingPathComponent(relative).path
            if let data = FileManager.default.contents(atPath: candidate) { return data }
        }
        // 兜底：按文件名在 Bundle 中查找
        let file = (relative as NSString).lastPathComponent
        let base = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        if let url = Bundle.main.url(forResource: base.isEmpty ? nil : base,
                                     withExtension: ext.isEmpty ? nil : ext) {
            return FileManager.default.contents(atPath: url.path)
        }
        return nil
    }

    private static func sanitized(_ name: String) -> String? {
        var path = name
        if path.hasPrefix("web/") { path = String(path.dropFirst(4)) }
        if path.hasPrefix("/") { path = String(path.dropFirst()) }
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains("..."), !components.contains("..") else { return nil }
        return components.joined(separator: "/")
    }
}

/// 内置网页服务 (Android: web/LHttpServer.java)
/// 与 LAN 协议共用 TCP 端口，按首 4 字节分流；协议、路由与 Android 端保持一致。
final class LWebServer: LHttpServicing {
    static let shared = LWebServer()

    private let engine = LHttpEngine()
    weak var service: LANService?
    private var themeCancellable: AnyCancellable?
    private let clientsGate = NSLock()
    private var clients: [LWebSocketServer] = []
    /// 网页自身发出的消息不再回推给网页端 (Android: broadcastMessage(shareWS=false))
    private var suppressForward = false
    private var routesRegistered = false

    /// 需要 token 鉴权的路径 (Android: LHttpServer.paths)
    private let authPaths = [
        "/apps", "/media", "/files", "/compressMedias", "/apkfile/*", "/file/*",
        "/wss", "/imageload/*", "/uploadFile", "/chatUploadFile", "/updateWebName",
    ]

    /// 侧边栏菜单，与 Android WEB_MENUS 一致
    private let webMenus: [[String: Any]] = [
        ["key": "apps", "text": "软件", "icon": "nav-item-media-apps"],
        ["key": "media", "text": "图片", "icon": "nav-item-media-img"],
        ["key": "files", "text": "文件列表", "icon": "nav-item-media-folder"],
        ["key": "chat", "text": "消息记录", "icon": "nav-item-media-record"],
        ["key": "draw", "text": "远程绘图", "icon": "nav-item-media-record"],
    ]

    private static let accessDenied = "访问权限已失效，请刷新主页后授权"
    private static let fileExpired = "下载失败,文件已失效!"

    // MARK: - 生命周期

    /// 对应 startBlendingModeHttpServer：注册路由并接管 TCP 层的 HTTP 分支
    func start(service: LANService) {
        self.service = service
        registerRoutes()
        engine.sortRoutePatterns()
        service.httpServer = self
        service.handleWebRequestHandler = { stream, head in
            self.engine.handleWebClient(stream, prefix: head)
        }
        service.onMessageAdded = { [weak self] content in
            self?.forwardLocalMessage(content)
        }
        themeCancellable = LSettings.shared.$themeMode
            .dropFirst()
            .sink { [weak self] mode in
                self?.sendThemeChange(mode.webTheme)
            }
        LLog.debug("web service ready on port \(LSettings.shared.tcpPort)")
    }

    func stop() {
        themeCancellable = nil
        service?.httpServer = nil
        service?.handleWebRequestHandler = nil
        service?.onMessageAdded = nil
        closeAllClients()
    }

    private var cacheDir: String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("LANShareWebCache")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - LHttpServicing

    func sendDeviceList() {
        var array: [[String: Any]] = []
        for device in service?.deviceManager.deviceList() ?? [] {
            array.append([
                "devName": device.devName,
                "devIP": device.devIP,
                "devPort": Int(device.devPort),
                "devMode": Int(device.devMode),
                "dataVersion": Int(device.dataVersion),
                "address": device.address,
            ])
        }
        broadcast(["cmd": WSCmd.syncDeviceList, "data": array])
    }

    func sendMessageToWeb(_ text: String, devName: String, devMode: Int32, messageType: Int,
                          filePath: String, isLeft: Bool, isClip: Bool) {
        let shown = isLeft ? devName : "\(devName) ← \(LSettings.shared.devName)"
        let payload: [String: Any] = [
            "cmd": WSCmd.sendMessage,
            "isLeft": isLeft,
            "message": text,
            "devName": shown.isEmpty ? LSettings.shared.devName : shown,
            "devType": Int(devMode),
            "messageType": messageType,
            "isClip": isClip,
            "filePath": filePath,
            "fileSize": "",
        ]
        broadcast(payload)
    }

    /// 单播给某个网页客户端 (Android: LHttpServer.sendMessage(webSocketServer, ...))
    func sendToDevice(_ text: String, device: Device, isClip: Bool) {
        guard let ws = device.webSocket as? LWebSocketServer, !ws.isClosed else { return }
        let payload: [String: Any] = [
            "cmd": WSCmd.sendMessage,
            "isLeft": false,
            "message": text,
            "devName": "\(device.devName) ← \(LSettings.shared.devName)",
            "devType": Int(device.devMode),
            "messageType": 0,
            "isClip": isClip,
            "filePath": "",
            "fileSize": "",
        ]
        try? ws.sendString(LJSON.string(payload))
    }

    func sendDrawEvent(_ json: String) {
        guard var obj = LJSON.object(from: json) else {
            broadcastRaw(json)
            return
        }
        obj["cmd"] = WSCmd.drawEvent
        broadcast(obj)
    }

    func sendClearDraw() {
        broadcast(["cmd": WSCmd.drawEvent, "action": "clear"])
    }

    func sendThemeChange(_ theme: String) {
        broadcast(["cmd": WSCmd.changeTheme, "theme": theme])
    }

    // MARK: - WebSocket 客户端管理

    private func addClient(_ ws: LWebSocketServer) {
        clientsGate.lock()
        clients.append(ws)
        clientsGate.unlock()
    }

    private func removeClient(_ ws: LWebSocketServer) {
        clientsGate.lock()
        clients.removeAll { $0 === ws }
        clientsGate.unlock()
    }

    private var clientSnapshot: [LWebSocketServer] {
        clientsGate.lock()
        defer { clientsGate.unlock() }
        return clients
    }

    private func closeAllClients() {
        for ws in clientSnapshot { ws.close() }
        clientsGate.lock()
        clients.removeAll()
        clientsGate.unlock()
    }

    /// 逐个发送，失败的连接顺带移除 (Android: sendMessage 迭代器逻辑)
    private func sendToClients(_ text: String, except: LWebSocketServer? = nil) {
        for ws in clientSnapshot {
            if let except, ws === except { continue }
            guard !ws.isClosed else {
                removeClient(ws)
                continue
            }
            do {
                try ws.sendString(text)
            } catch {
                ws.close()
                removeClient(ws)
            }
        }
    }

    private func broadcast(_ payload: [String: Any]) {
        sendToClients(LJSON.string(payload))
    }

    private func broadcastRaw(_ text: String) {
        sendToClients(text)
    }

    /// 本地产生的消息同步到网页端 (Android: UdpServerManager/FileTransferManager 直接调用 sendMessage)
    private func forwardLocalMessage(_ content: MessageContent) {
        if suppressForward { return }
        guard content.isLeft else { return }
        if let file = content as? MessageFileContent {
            let messageType = file.isMedia ? 1 : 2
            sendMessageToWeb(file.name, devName: file.userName, devMode: file.devMode,
                             messageType: messageType, filePath: file.path, isLeft: true, isClip: false)
            return
        }
        guard content.messageType == 1 else { return }
        let isClip = (content as? MessageTextContent)?.isClip ?? false
        sendMessageToWeb(content.content, devName: content.userName, devMode: content.devMode,
                         messageType: 0, filePath: "", isLeft: true, isClip: isClip)
    }

    // MARK: - 路由

    private func registerRoutes() {
        guard !routesRegistered else { return }
        routesRegistered = true

        engine.requestFilter = { [weak self] request, response, handler in
            guard let self else { throw LSError.io("web server released") }
            if LSettings.shared.webOpen {
                try handler(request, response)
                return
            }
            for path in self.authPaths where self.engine.pathMatches(path, request.requestPath) {
                let token: String?
                if request.requestMethod.compare("POST", options: .caseInsensitive) == .orderedSame {
                    token = request.getHeaderValue("token")
                } else {
                    token = request.getQueryParam("token")
                }
                guard let token, let record = self.service?.tokenDB.query(token: token), record.pass == 1 else {
                    throw LWebError.move(Self.accessDenied, "/")
                }
            }
            try handler(request, response)
        }

        engine.addPath("/checkPass") { [weak self] request, response in
            guard let self else { return }
            let token = request.getHeaderValue("token") ?? ""
            let pass = (self.service?.tokenDB.query(token: token)?.pass ?? 0) == 1
            try response.writeString(LJSON.string(["pass": pass]))
        }

        engine.addPath("/initConfig") { [weak self] request, response in
            guard let self else { return }
            try self.initConfig(request, response)
        }

        engine.addPath("/updateWebName") { [weak self] request, response in
            guard let self else { return }
            let body = request.getRequestBody() ?? "{}"
            let webName = LJSON.object(from: body)?["webName"] as? String ?? ""
            if let token = request.getHeaderValue("token") {
                self.service?.tokenDB.setName(token: token, name: webName)
            }
            try response.writeEmpty()
        }

        engine.addPath("/sharefile/*") { [weak self] request, response in
            guard let self else { return }
            guard let uuid = request.getQueryParam("uuid"),
                  let record = self.service?.fileShareDB.queryShare(id: uuid),
                  FileManager.default.fileExists(atPath: record.path) else {
                throw LWebError.notFound("404 Not Found")
            }
            if record.days == -1 {
                if record.downloaded {
                    try response.writeString(Self.fileExpired, contentType: LHttpConstant.textContentType)
                    return
                }
            } else if !Self.isFutureDate(days: record.days, timestamp: record.time) {
                try response.writeString(Self.fileExpired, contentType: LHttpConstant.textContentType)
                return
            }
            try response.writeFile(record.path)
            self.service?.fileShareDB.updateDownloaded(id: uuid, downloaded: true)
        }

        engine.addPath("/chatUploadFile") { [weak self] request, response in
            guard let self, let service = self.service else { return }
            let size = self.chatUpload(request, service: service)
            guard let size else {
                try response.write500()
                return
            }
            try response.writeString("文件上传成功，大小: \(LHttpSocketUtils.computeSize(size))")
        }

        engine.addPath("/uploadFile") { [weak self] request, response in
            guard let self, let service = self.service else { return }
            let dir = (LSettings.shared.fileSavePath as NSString).appendingPathComponent("网页收到的文件")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            guard let upload = request.transferUploadFile(toDirectory: dir) else {
                try response.write500()
                return
            }
            let entry = FileEntry(name: upload.fileName, path: upload.filePath, isDirectory: false,
                                  size: upload.fileSize, modified: Date())
            let file = LFileStore.message(for: entry)
            file.id = MessageContent.newId()
            file.userName = "(网页设备)"
            file.isLeft = true
            file.devMode = DevMode.windows.rawValue
            file.progress = 100
            file.status = MessageStatus.success
            file.stateMessage = "接收成功"
            service.showProgress([file])
            try response.writeString("文件上传成功，大小: \(LHttpSocketUtils.computeSize(upload.fileSize))")
        }

        engine.addPath("/apps") { request, response in
            // iOS 无法枚举已安装应用，保持与 Android 相同的响应结构
            _ = request
            try response.writeString(LJSON.string(["list": [[String: Any]]()]))
        }

        engine.addPath("/imageload/*") { [weak self] request, response in
            guard let self else { return }
            guard let indexText = request.getQueryParam("index"), let index = Int(indexText) else {
                try response.write404()
                return
            }
            LMediaIndex.shared.ensureBuilt()
            guard let data = LMediaIndex.shared.thumbnailData(index: index) else {
                try response.write404()
                return
            }
            try response.writeBytes(Array(data), contentType: LHttpConstant.streamContextImage)
        }

        engine.addPath("/files") { [weak self] request, response in
            guard let self else { return }
            try self.listFiles(request, response)
        }

        engine.addPath("/file/*") { request, response in
            guard let raw = request.getQueryParam("path") else {
                try response.write404()
                return
            }
            let resolved = LMediaIndex.shared.resolve(path: raw) ?? Self.sandboxPath(raw)
            guard let resolved, FileManager.default.fileExists(atPath: resolved) else {
                try response.write404()
                return
            }
            try response.writeFile(resolved)
        }

        engine.addPath("/media") { [weak self] request, response in
            guard let self else { return }
            try self.mediaList(request, response)
        }

        engine.addPath("/downloadZipFile") { [weak self] request, response in
            guard let self else { return }
            guard let temp = request.getQueryParam("tempFile"),
                  let full = Self.childPath(self.cacheDir, temp),
                  FileManager.default.fileExists(atPath: full) else {
                try response.write404()
                return
            }
            let fileName = (full as NSString).lastPathComponent
            let encoded = LUrlCoding.encode(fileName).replacingOccurrences(of: "+", with: "%20")
            response.addHeader("Content-Disposition",
                               "attachment; filename=\"\(fileName)\"; filename*=UTF-8''\(encoded)")
            try response.writeFile(full)
            try? FileManager.default.removeItem(atPath: full)
        }

        engine.addPath("/compressFiles") { [weak self] request, response in
            guard let self else { return }
            let body = LJSON.object(from: request.getRequestBody() ?? "{}")
            let paths = (body?["list"] as? [Any])?.compactMap { $0 as? String } ?? []
            let temp = (self.cacheDir as NSString).appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).zip")
            let zip = LZipWriter(path: temp)
            for path in paths {
                guard let real = Self.sandboxPath(path) else { continue }
                let parent = (real as NSString).deletingLastPathComponent
                zip.appendRecursive(real, beginIndex: parent.count + 1)
            }
            zip.finish()
            try response.writeString(LJSON.string(["tempFile": (temp as NSString).lastPathComponent]))
        }

        engine.addPath("/compressMedias") { [weak self] request, response in
            guard let self else { return }
            LMediaIndex.shared.ensureBuilt()
            let body = LJSON.object(from: request.getRequestBody() ?? "{}")
            let list = (body?["list"] as? [[String: Any]]) ?? []
            let folders = LMediaIndex.shared.photoFolders
            let temp = (self.cacheDir as NSString).appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).zip")
            let zip = LZipWriter(path: temp)
            for item in list {
                let isDirectory = (item["isDirectory"] as? NSNumber)?.boolValue ?? false
                let index = (item["index"] as? NSNumber)?.intValue ?? -1
                guard index >= 0, index < folders.count else { continue }
                let folder = folders[index]
                if isDirectory {
                    for media in folder.images {
                        self.zipMedia(zip, media: media, folder: folder)
                    }
                } else {
                    let sub = (item["subIndex"] as? NSNumber)?.intValue ?? -1
                    guard sub >= 0, sub < folder.images.count else { continue }
                    zipMedia(zip, media: folder.images[sub], folder: folder)
                }
            }
            zip.finish()
            try response.writeString(LJSON.string(["tempFile": (temp as NSString).lastPathComponent]))
        }

        engine.addPath("/drawable") { [weak self] request, response in
            guard let self else { return }
            let name = request.getQueryParam("name") ?? ""
            guard !name.isEmpty,
                  let data = LWebResources.data(for: "web/images/\(name).png")
                    ?? LWebResources.data(for: "web/images/\(name).jpg") else {
                try response.write404()
                return
            }
            try response.writeBytes(Array(data), contentType: LHttpConstant.streamContextImage)
        }

        // 静态资源：web + 路径
        for route in ["/css/*", "/js/*", "/images/*"] {
            engine.addPath(route) { [weak self] request, response in
                guard let self else { return }
                try self.serveStatic("web" + request.requestPath, response)
            }
        }

        engine.addPath("/favicon.ico") { [weak self] _, response in
            guard let self else { return }
            try self.serveStatic("web/images/lanshare.png", response)
        }

        engine.addPath("/") { [weak self] _, response in
            guard let self else { return }
            try self.serveStatic("web/lanshare.html", response)
        }

        engine.addPath("/wss") { [weak self] request, response in
            self?.handleWebSocket(request, response)
        }
    }

    private func serveStatic(_ name: String, _ response: LHttpResponse) throws {
        guard let data = LWebResources.data(for: name) else {
            try response.write404()
            return
        }
        let ext = (name as NSString).pathExtension
        try response.writeBytes(Array(data), contentType: LContentTypes.myMimeType(forExtension: ext))
    }

    // MARK: - /initConfig

    private func initConfig(_ request: LHttpRequest, _ response: LHttpResponse) throws {
        let clientIP = request.clientIP
        var token = request.getHeaderValue("token") ?? ""
        var name = "网页设备" + Self.randomString(6)
        var pass = false
        var notice = false
        let tokenDB = service?.tokenDB

        if let custom = tokenDB?.query(customIp: clientIP) {
            pass = custom.pass == 1
            if custom.name.isEmpty {
                tokenDB?.setName(token: custom.token, name: name)
            } else {
                name = custom.name
            }
            token = custom.token
        } else if token.isEmpty {
            token = LHttpSocketUtils.uuid()
            tokenDB?.add(token: token, custom: false, pass: 0, ip: clientIP, name: name)
            if LSettings.shared.webOpen {
                pass = true
            } else {
                notice = true
            }
        } else if let exist = tokenDB?.query(token: token) {
            if exist.pass != 1 { notice = true }
            pass = exist.pass == 1
            name = exist.name
        } else {
            tokenDB?.add(token: token, custom: false, pass: 0, ip: clientIP, name: name)
            if LSettings.shared.webOpen {
                pass = true
            } else {
                notice = true
            }
        }

        if notice {
            service?.requestWebClientApproval(token: token, ip: clientIP, name: name)
        }

        let payload: [String: Any] = [
            "rootPath": LFileStore.root,
            "token": token,
            "name": name,
            "pass": pass,
            "theme": LSettings.shared.themeMode.webTheme,
            "menus": webMenus,
        ]
        try response.writeString(LJSON.string(payload))
    }

    // MARK: - /files

    private func listFiles(_ request: LHttpRequest, _ response: LHttpResponse) throws {
        let body = LJSON.object(from: request.getRequestBody() ?? "{}")
        let isBack = (body?["isBack"] as? NSNumber)?.boolValue ?? false
        let rawPath = LUrlCoding.decode(body?["path"] as? String ?? "")
        let root = LFileStore.root
        var dir = root
        if !rawPath.isEmpty, let candidate = Self.sandboxPath(rawPath) {
            dir = isBack ? (LFileStore.parent(of: candidate) ?? root) : candidate
        }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) || !isDir.boolValue {
            dir = root
        }

        let showHidden = LSettings.shared.showHiddenFiles
        let entries = LFileStore.entries(in: dir, showHidden: showHidden, sort: LSettings.shared.fileSortMethod)
        let formatter = Self.dateFormatter

        var list: [[String: Any]] = [
            ["name": "...", "length": 0, "path": dir, "isFile": true, "time": "", "isDirectory": false]
        ]
        for entry in entries {
            // 与 Android 一致：开启隐藏文件时反而过滤掉点文件
            if showHidden, entry.name.hasPrefix(".") { continue }
            list.append([
                "name": entry.name,
                "length": entry.isDirectory ? 0 : entry.size,
                "path": entry.path,
                "isFile": !entry.isDirectory,
                "time": formatter.string(from: entry.modified),
                "isDirectory": entry.isDirectory,
            ])
        }
        try response.writeString(LJSON.string(["path": dir, "list": list]))
    }

    // MARK: - /media

    private func mediaList(_ request: LHttpRequest, _ response: LHttpResponse) throws {
        LMediaIndex.shared.ensureBuilt()
        let body = LJSON.object(from: request.getRequestBody() ?? "{}")
        let folderIndex = (body?["folderIndex"] as? NSNumber)?.intValue ?? -1
        let folders = LMediaIndex.shared.photoFolders
        var array: [[String: Any]] = []

        if folderIndex == -1 {
            for (i, folder) in folders.enumerated() where !folder.images.isEmpty {
                let cover = folder.images[0]
                array.append([
                    "name": "\(folder.name)(\(folder.images.count))",
                    "path": cover.path,
                    "isDirectory": true,
                    "count": folder.images.count,
                    "index": i,
                    "imgIndex": cover.index,
                    "isVideo": false,
                ])
            }
        } else if folderIndex >= 0, folderIndex < folders.count {
            let folder = folders[folderIndex]
            for (i, media) in folder.images.enumerated() {
                var item: [String: Any] = [
                    "name": media.name,
                    "path": media.path,
                    "length": media.length,
                    "isDirectory": false,
                    "index": folderIndex,
                    "isVideo": media.isVideo,
                    "imgIndex": media.index,
                    "subIndex": i,
                ]
                if media.isVideo { item["videoTime"] = media.videoTime }
                array.append(item)
            }
        }
        try response.writeString(LJSON.string(array))
    }

    private func zipMedia(_ zip: LZipWriter, media: LWebMedia, folder: LWebPhotoFolder) {
        guard let real = LMediaIndex.shared.resolve(path: media.path) else { return }
        let safeName = media.name.replacingOccurrences(of: "/", with: "_")
        zip.append(file: real, entryName: "\(folder.name)/\(safeName)")
    }

    // MARK: - /chatUploadFile

    /// 流式转发到指定设备，返回转发字节数；失败返回 nil
    private func chatUpload(_ request: LHttpRequest, service: LANService) -> Int64? {
        guard let address = request.getQueryParam("address"),
              let device = service.deviceManager.device(for: address), !device.isWeb else {
            return nil
        }
        guard let upload = request.getSingleUploadInputStream() else { return nil }
        let stream = MessageStreamContent(name: upload.fileName ?? "", length: upload.fileSize)
        stream.source = { upload.read(65_536) }
        stream.isLeft = false
        stream.userName = request.clientIP

        let sem = DispatchSemaphore(value: 0)
        var ok = false
        service.fileSend.send(device: device, files: [stream]) { files in
            ok = files.allSatisfy { $0.isSuccess }
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 600) == .success else {
            stream.isTransfer = false
            return nil
        }
        return ok ? upload.fileSize : nil
    }

    // MARK: - /wss

    private func handleWebSocket(_ request: LHttpRequest, _ response: LHttpResponse) {
        let socket = request.socket
        guard let ws = try? LWebSocketServer(secWebSocketKey: request.getHeaderValue("Sec-WebSocket-Key"),
                                             socket: socket) else { return }
        // 长连接：取消读超时，由前端 30s 心跳保活
        socket.setReadTimeout(seconds: 0)
        addClient(ws)

        let token = request.getQueryParam("token") ?? ""
        let record = service?.tokenDB.query(token: token)
        let webDevice = Device(devName: record?.name ?? "网页设备", devIP: request.clientIP,
                               devPort: Int32(socket.remotePort))
        webDevice.devMode = DevMode.web.rawValue
        webDevice.canRemove = false
        webDevice.uniqueUUid = token
        webDevice.dataVersion = Int32(LConst.dataVersion)
        webDevice.webSocket = ws
        service?.deviceManager.addWebDevice(webDevice)
        sendDeviceList()

        while !ws.isClosed {
            guard let text = nextWebSocketMessage(ws) else { break }
            handleWebSocketMessage(text, from: ws, device: webDevice, token: token)
        }

        ws.close()
        removeClient(ws)
        service?.deviceManager.removeWebDevice(address: webDevice.address)
        sendDeviceList()
    }

    /// 读取下一条文本消息；ping/pong 等控制帧继续等待
    private func nextWebSocketMessage(_ ws: LWebSocketServer) -> String? {
        while !ws.isClosed {
            do {
                guard let frame = try ws.readFrame() else { continue }
                guard let data = frame.data else { return nil }
                return String(decoding: data, as: UTF8.self)
            } catch {
                return nil
            }
        }
        return nil
    }

    private func handleWebSocketMessage(_ text: String, from ws: LWebSocketServer,
                                        device webDevice: Device, token: String) {
        guard let json = LJSON.object(from: text) else { return }
        let cmd = (json["cmd"] as? NSNumber)?.intValue ?? 0

        switch cmd {
        case WSCmd.sendMessage:
            let message = json["message"] as? String ?? ""
            guard !message.isEmpty else { return }
            let selected = json["selectedDevice"] as? String ?? ""
            let isClip = (json["isClip"] as? NSNumber)?.boolValue ?? false
            let target: Device? = selected.isEmpty ? nil : service?.deviceManager.device(for: selected)
            let content = MessageTextContent()
            content.id = MessageContent.newId()
            content.content = message
            content.isLeft = true
            content.isClip = isClip
            content.userName = wsName(token)
            content.toUser = target?.devName ?? LConst.allDevicesKey
            content.status = MessageStatus.success
            // 网页自己已经渲染过这条消息，回推会造成重复
            suppressForward = true
            service?.addMessage(content)
            suppressForward = false
            service?.udpServer.broadcastMessage(to: target, text: message, isClip: isClip, shareWS: false)

        case WSCmd.drawEvent:
            var relay = json
            relay["from"] = "web"
            sendToClients(LJSON.string(relay), except: ws)
            guard let event = LDrawEvent.from(jsonString: text) else { return }
            LThread.main { [weak self] in
                self?.service?.drawSyncManager.onRemoteDraw?(event)
            }

        case WSCmd.ping:
            try? ws.sendString(LJSON.string(["cmd": WSCmd.pong]))

        default:
            break
        }
    }

    private func wsName(_ token: String) -> String {
        service?.tokenDB.query(token: token)?.name ?? "网页设备"
    }

    // MARK: - 工具

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// 对应 DateUtils.isFutureDate(days, timestamp)：now + days 仍晚于时间戳则未过期
    static func isFutureDate(days: Int, timestamp: Int64) -> Bool {
        let future = Date().addingTimeInterval(TimeInterval(days * 86_400))
        return future.timeIntervalSince1970 > Double(timestamp) / 1000
    }

    /// 只允许访问沙盒内路径，越界返回 nil
    static func sandboxPath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let normalized = (path as NSString).standardizingPath
        let container = (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "")
        let tmp = NSTemporaryDirectory()
        let library = (NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true).first ?? "")
        let allowed = [container, String((tmp as NSString).deletingLastPathComponent), library]
        for base in allowed where !base.isEmpty && normalized.hasPrefix(base) {
            return normalized
        }
        return nil
    }

    static func childPath(_ dir: String, _ name: String) -> String? {
        let full = (dir as NSString).appendingPathComponent((name as NSString).lastPathComponent)
        return full.hasPrefix(dir) ? full : nil
    }

    static func randomString(_ length: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in chars.randomElement() ?? "0" })
    }
}

/// 网页 JSON 编解码
enum LJSON {
    static func string(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) || value is [Any] || value is String else {
            return "{}"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func object(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
