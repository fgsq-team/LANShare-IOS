import Foundation

/// 一次文件传输的上下文 (Android: service/version/four/FileTransfer + five/FileTransferV5)
final class LFileTransfer {
    var fromDevice: Device
    var files: [MessageFileContent]
    var resumeMap: [String: Int64] = [:]
    var isFinished: Bool { files.allSatisfy { $0.isFinal } }

    init(fromDevice: Device, files: [MessageFileContent]) {
        self.fromDevice = fromDevice
        self.files = files
    }
}

/// 发送端 (Android: service/version/five/FileSenderV5.java + four/FileSend.java)
final class LFileSender {
    weak var service: LANService?
    private let chunkSize = 1024 * 1024

    init(service: LANService?) {
        self.service = service
    }

    // MARK: - 文件发送

    /// 向单个设备发送一组文件（每个设备一条独立连接）
    /// completion 在连接关闭后回调，网页上传需要等待它再回复 HTTP 响应
    func send(device toDevice: Device, files: [MessageFileContent],
              completion: (([MessageFileContent]) -> Void)? = nil) {
        guard let from = service?.deviceManager.matchLocalDevice(for: toDevice) ?? service?.deviceManager.selfDevices.first else {
            failAll(files, to: toDevice, reason: "本机网卡信息为空")
            completion?(files)
            return
        }
        // 地址为空/端口为 0 说明这条设备记录不是来自 UDP 通告（例如只完成了扫码配对或来自网页端），
        // 直接建连必然失败，先把记录本身的问题报出来。
        guard !toDevice.devIP.isEmpty, toDevice.devPort > 0 else {
            failAll(files, to: toDevice, reason: "对方地址无效 \(toDevice.address)")
            completion?(files)
            return
        }
        let useV5 = toDevice.dataVersion >= LVersion.dataVersion5
        let useV4 = toDevice.dataVersion >= LVersion.dataVersion4
        LLog.debug("send \(files.count) file(s) to \(toDevice.address) v\(toDevice.dataVersion) "
                   + "from \(from.devIP):\(from.devPort)")
        LThread.run { [weak self] in
            guard let self else { return }
            do {
                let stream = try LTcpStream.connect(host: toDevice.devIP, port: Int(toDevice.devPort))
                try stream.writeInt(LConst.magicNum)
                let transfer = try self.openHandshake(stream: stream, from: from, to: toDevice,
                                                      files: files, useV5: useV5, useV4: useV4)
                if let transfer {
                    self.startCancelListener(stream: stream, transfer: transfer)
                    try self.transferFiles(stream: stream, transfer: transfer, encData: LSettings.shared.encData,
                                           useV5: useV5)
                }
                stream.close()
            } catch {
                failAll(files, to: toDevice, reason: "\(error)")
            }
            completion?(files)
        }
    }

    /// 握手 + 请求，返回 nil 表示对方拒绝
    private func openHandshake(stream: LTcpStream, from: Device, to toDevice: Device,
                               files: [MessageFileContent], useV5: Bool, useV4: Bool) throws -> LFileTransfer? {
        let senderUuid = from.uniqueUUid
        // 协议头
        try stream.writeInt(useV5 ? LCmd.newVersion5 : (useV4 ? LCmd.newVersion4 : LCmd.newVersion5))
        var selfDevice = from
        selfDevice.devMode = LSelfDeviceType.value
        try stream.writeString(selfDevice.jsonString)

        let encData = LSettings.shared.encData
        var fileArray: [[String: Any]] = []
        for file in files {
            var entry: [String: Any] = [:]
            if file.fileType == MessageFileContent.fileTypeFolder, let folder = file as? MessageFolderContent {
                var children: [[String: Any]] = []
                var total: Int64 = 0
                folder.length = 0
                let items = buildFolderTree(root: file.path, folder: folder)
                folder.fileCount = items.count
                folder.children = items
                for child in items {
                    if child.length > 0, !child.path.isEmpty {
                        child.fileId = ResumeStore.stableId(seed: "\(senderUuid)|\(child.path)|\(child.length)")
                    } else if child.fileId.isEmpty {
                        child.fileId = MessageContent.newId()
                    }
                    children.append(["fileId": child.fileId, "name": child.name,
                                     "length": child.length, "fileType": child.fileType])
                    total += child.length
                }
                folder.length = total
                entry["fileCount"] = items.count
                entry["children"] = children
            } else if file.fileType == MessageFileContent.fileTypeImage || file.fileType == MessageFileContent.fileTypeVideo,
                      let media = file as? MessageMediaContent {
                entry["video"] = media.isVideo
                entry["videoTime"] = media.videoTime
                entry["gif"] = media.isGif
            }

            // 顶层 fileId：新发送用随机 UUID，续传复用记录自带的 fileId
            if file.fileId.isEmpty {
                file.fileId = MessageContent.newId()
            }
            file.id = file.fileId
            file.isLeft = false
            file.userName = from.devName
            file.toUser = toDevice.devName
            entry["fileId"] = file.fileId
            entry["name"] = file.name
            entry["length"] = file.length
            entry["fileType"] = file.fileType
            entry["toUser"] = toDevice.devName
            fileArray.append(entry)
        }

        let request: [String: Any] = [
            "fromDevice": mergedDeviceJson(from, mode: LSelfDeviceType.value),
            "type": 0,
            "groupId": 0,
            "files": fileArray,
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestJson = String(decoding: requestData, as: UTF8.self)

        try stream.writeInt(LCmd.fsShareFile)
        try stream.writeBoolean(encData)
        try stream.writeString(requestJson)

        let response = try stream.readInt()
        guard response == LCmd.fsAgree else {
            // 回复码不是「同意」：-1/其它值说明对端没按 V5 回包，多半是握手 JSON 没被解析成功
            let reason = response == LCmd.fsNotAgree ? "对方拒绝接收文件" : "对方回包异常(码 \(response))"
            LLog.error("handshake to \(toDevice.address) failed: \(reason)")
            for file in files { finish(file, success: false, reason: reason) }
            service?.showToast(reason)
            return nil
        }
        let transfer = LFileTransfer(fromDevice: from, files: files)
        if useV5 {
            transfer.resumeMap = try readResumeMap(stream)
        }
        service?.showProgress(files)
        return transfer
    }

    private func mergedDeviceJson(_ device: Device, mode: Int32) -> [String: Any] {
        var json = device.jsonObject
        json["devMode"] = mode
        json["dataVersion"] = Int32(LConst.dataVersion)
        return json
    }

    private func readResumeMap(_ stream: LTcpStream) throws -> [String: Int64] {
        guard let json = try stream.readString(), !json.isEmpty,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var map: [String: Int64] = [:]
        for (k, v) in obj {
            if let n = v as? NSNumber { map[k] = n.int64Value }
        }
        return map
    }

    /// 递归展开文件夹（子项 name 为相对路径）
    private func buildFolderTree(root: String, folder: MessageFolderContent) -> [MessageFileContent] {
        var items: [MessageFileContent] = []
        let fm = FileManager.default
        func walk(_ dir: String, _ relative: String) {
            guard let children = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for childName in children.sorted() {
                if childName.hasPrefix(".") { continue }
                let fullPath = (dir as NSString).appendingPathComponent(childName)
                let relPath = relative.isEmpty ? childName : relative + "/" + childName
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    walk(fullPath, relPath)
                } else {
                    let item = MessageFileContent(name: relPath, path: fullPath,
                                                  length: ResumeStore.fileSize(fullPath))
                    items.append(item)
                }
            }
        }
        walk(root, "")
        return items
    }

    // MARK: - 数据流

    private func transferFiles(stream: LTcpStream, transfer: LFileTransfer, encData: Bool, useV5: Bool) throws {
        for file in transfer.files {
            if file.fileType == MessageFileContent.fileTypeFolder, let folder = file as? MessageFolderContent {
                try sendFolder(stream: stream, transfer: transfer, folder: folder, encData: encData, useV5: useV5)
            } else {
                try sendFile(stream: stream, transfer: transfer, file: file, encData: encData, useV5: useV5)
            }
        }
    }

    private func sendFolder(stream: LTcpStream, transfer: LFileTransfer, folder: MessageFolderContent,
                            encData: Bool, useV5: Bool) throws {
        let folderSize = folder.length
        var subTotal: Int64 = 0
        var failed = false
        for child in folder.children {
            guard child.length > 0 else { continue }
            let offset = useV5 ? min(max(0, transfer.resumeMap[child.fileId] ?? 0), child.length) : 0
            if offset >= child.length {
                subTotal += child.length
                continue
            }
            guard let reader = try? LFileReader(path: child.path) else { failed = true; break }
            defer { reader.close() }
            do {
                if offset > 0 { try reader.skip(to: offset) }
                let sent = try sendStream(stream: stream, transfer: transfer, base: folder, item: child,
                                         reader: reader, progressBase: subTotal + offset, finalSize: folderSize,
                                         startOffset: offset, encData: encData)
                if sent < 0 { failed = true; break }
                subTotal += sent
            } catch {
                failed = true
                break
            }
        }
        finish(folder, success: !failed && subTotal == folderSize)
    }

    private func sendFile(stream: LTcpStream, transfer: LFileTransfer, file: MessageFileContent,
                          encData: Bool, useV5: Bool) throws {
        let length = file.length
        var total: Int64 = 0
        if length > 0 {
            let offset = useV5 ? min(max(0, transfer.resumeMap[file.fileId] ?? 0), length) : 0
            if offset >= length {
                total = length
            } else if let streamSource = (file as? MessageStreamContent)?.source {
                let reader = LFileReader(stream: streamSource)
                defer { reader.close() }
                // 流式来源无法 seek，同样要读丢续传前缀 (Android: ResumeStore.skipFully 对两类源都调用)
                if offset > 0 { try reader.skip(to: offset) }
                total = try sendStream(stream: stream, transfer: transfer, base: file, item: file,
                                       reader: reader, progressBase: offset, finalSize: length,
                                       startOffset: offset, encData: encData)
            } else {
                let reader = try LFileReader(path: file.path)
                defer { reader.close() }
                if offset > 0 { try reader.skip(to: offset) }
                total = try sendStream(stream: stream, transfer: transfer, base: file, item: file,
                                       reader: reader, progressBase: offset, finalSize: length,
                                       startOffset: offset, encData: encData)
            }
        }
        finish(file, success: total == length)
    }

    /// 返回该文件完成的绝对字节数，失败返回 -1
    private func sendStream(stream: LTcpStream, transfer: LFileTransfer, base: MessageFileContent,
                            item: MessageFileContent, reader: LFileReader, progressBase: Int64,
                            finalSize: Int64, startOffset: Int64, encData: Bool) throws -> Int64 {
        var fileIndex = startOffset
        var sent: Int64 = 0
        var targetSize = item.length - startOffset
        var lastProgress = 0
        while true {
            if !base.isTransfer {
                try stream.writeInt(LCmd.newFsBreak)
                return -1
            }
            guard let chunk = reader.read(chunkSize), !chunk.isEmpty else { break }
            var buffer = chunk
            if encData {
                LCrypto.maskEncData(&buffer, len: buffer.count, off: 0, index: fileIndex)
            }
            try stream.writeInt(Int32(buffer.count))
            try stream.write(buffer)
            fileIndex += Int64(buffer.count)
            sent += Int64(buffer.count)
            targetSize -= Int64(buffer.count)
            let progress = finalSize > 0 ? Int((progressBase + sent) * 100 / finalSize) : 100
            if progress > lastProgress {
                lastProgress = progress
                base.progress = progress
                service?.progressUpdate(base)
            }
            if targetSize <= 0 { break }
        }
        return fileIndex == item.length ? fileIndex : -1
    }

    /// 监听接收端的取消指令（同一条连接反向通道，读到的字符串即被取消的 fileId）
    private func startCancelListener(stream: LTcpStream, transfer: LFileTransfer) {
        LThread.run {
            var errorCount = 0
            while true {
                do {
                    guard let fileId = try stream.readString() else { return }
                    if fileId.isEmpty { continue }
                    for item in transfer.files where item.fileId == fileId {
                        item.isTransfer = false
                    }
                } catch {
                    errorCount += 1
                    if errorCount > 10 { return }
                    LThread.sleep(seconds: 0.1)
                }
            }
        }
    }

    private func finish(_ file: MessageFileContent, success: Bool, reason: String? = nil) {
        if file.isFinal { return }
        // 状态位在工作线程同步写入(同 Android onItemFinish)，否则调用方的完成回调会读到进行中
        if success {
            file.status = MessageStatus.success
            file.stateMessage = "发送成功"
        } else {
            file.status = MessageStatus.error
            file.stateMessage = reason ?? "发送失败"
        }
        LThread.main { [weak self] in
            self?.service?.closeProgress(file)
        }
    }

    /// 统一失败出口：真机上「发送失败但对方毫无反应」必须能看到断在哪一步，否则无法排查
    private func failAll(_ files: [MessageFileContent], to device: Device, reason: String) {
        LLog.error("send to \(device.address) failed: \(reason)")
        for file in files where !file.isFinal {
            finish(file, success: false, reason: "发送失败：\(reason)")
        }
        service?.showToast("发送失败：\(reason)")
    }

    // MARK: - 其它 TCP 命令

    /// 长文本消息 (FS_MESSAGE)
    func sendTCPMessage(to device: Device, encrypted: String, isClip: Bool) {
        guard let from = service?.deviceManager.matchLocalDevice(for: device) else { return }
        LThread.run { [weak self] in
            guard let self else { return }
            do {
                let stream = try LTcpStream.connect(host: device.devIP, port: Int(device.devPort))
                try stream.writeInt(LConst.magicNum)
                try stream.writeInt(device.dataVersion >= LVersion.dataVersion5 ? LCmd.newVersion5 : LCmd.newVersion4)
                var selfDevice = from
                selfDevice.devMode = LSelfDeviceType.value
                try stream.writeString(selfDevice.jsonString)
                try stream.writeInt(LCmd.fsMessage)
                try stream.writeBoolean(isClip)
                try stream.writeString(encrypted)
                stream.close()
            } catch {
                LLog.error("sendTCPMessage failed: \(error)")
            }
        }
    }

    /// 媒体同步协商 (FS_GET_NO_SYNC_MEDIA)：返回对方缺少的 mediaId
    func requestNoSyncMedia(to device: Device, mediaIds: [Int64],
                            completion: @escaping ([Int64]) -> Void) {
        guard let from = service?.deviceManager.matchLocalDevice(for: device) else {
            completion(mediaIds)
            return
        }
        LThread.run { [weak self] in
            guard let self else { return }
            do {
                let stream = try LTcpStream.connect(host: device.devIP, port: Int(device.devPort))
                try stream.writeInt(LConst.magicNum)
                try stream.writeInt(device.dataVersion >= LVersion.dataVersion5 ? LCmd.newVersion5 : LCmd.newVersion4)
                var selfDevice = from
                selfDevice.devMode = LSelfDeviceType.value
                try stream.writeString(selfDevice.jsonString)
                try stream.writeInt(LCmd.fsGetNoSyncMedia)
                let idsJson = "[" + mediaIds.map { "\($0)" }.joined(separator: ",") + "]"
                try stream.writeString(idsJson)
                let reply = try stream.readString() ?? "[]"
                if let data = reply.data(using: .utf8),
                   let arr = try? JSONSerialization.jsonObject(with: data) as? [NSNumber] {
                    completion(arr.map { $0.int64Value })
                } else {
                    completion(mediaIds)
                }
                stream.close()
            } catch {
                LLog.error("requestNoSyncMedia failed: \(error)")
                completion(mediaIds)
            }
        }
    }

    /// 绘图同步请求 (FS_DRAW_SYNC_REQUEST)，成功后返回长连接
    func openDrawSync(to device: Device, completion: @escaping (Result<LTcpStream, Error>) -> Void) {
        guard let from = service?.deviceManager.matchLocalDevice(for: device) else {
            completion(.failure(LSError.io("no local device")))
            return
        }
        LThread.run {
            do {
                let stream = try LTcpStream.connect(host: device.devIP, port: Int(device.devPort))
                try stream.writeInt(LConst.magicNum)
                try stream.writeInt(LCmd.newVersion4)
                var selfDevice = from
                selfDevice.devMode = LSelfDeviceType.value
                try stream.writeString(selfDevice.jsonString)
                try stream.writeInt(LCmd.fsDrawSyncRequest)
                try stream.writeString(LSettings.shared.devName)
                stream.setReadTimeout(seconds: 60)
                let reply = try stream.readInt()
                stream.setReadTimeout(seconds: 0)
                guard reply == LCmd.fsDrawSyncAccept else {
                    stream.close()
                    completion(.failure(LSError.io("peer rejected draw sync")))
                    return
                }
                completion(.success(stream))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// 扫码配对 (FS_ADD_DEVICE)，legacy DataEnc 通道，不混淆
    func addDeviceByQR(qr qrContent: String, completion: @escaping (Result<Device, Error>) -> Void) {
        let parts = qrContent.split(separator: "-", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, String(parts[0]) == LConst.key else {
            completion(.failure(LSError.io("qr content invalid")))
            return
        }
        let isIPv6 = parts[1] == "1"
        let ip = String(parts[2])
        guard let port = Int(parts[3]) else {
            completion(.failure(LSError.io("qr port invalid")))
            return
        }
        LThread.run { [weak self] in
            guard let self, let service = self.service else { return }
            let targetIP: String
            let from: Device?
            if isIPv6 {
                targetIP = ip
                from = service.deviceManager.selfDevices.first
            } else {
                let candidates = ip.split(separator: ",").map(String.init)
                var matched: (String, Device)?
                for local in service.deviceManager.selfDevices {
                    if let hit = candidates.first(where: { NetUtils.subNet($0, local.devIP, local.devNetMask) }) {
                        matched = (hit, local)
                        break
                    }
                }
                guard let m = matched else {
                    completion(.failure(LSError.io("ip 不在本地网络")))
                    return
                }
                targetIP = m.0
                from = m.1
            }
            guard let from else {
                completion(.failure(LSError.io("no local device")))
                return
            }
            do {
                let stream = try LTcpStream.connect(host: targetIP, port: port)
                try stream.writeInt(LConst.magicNum)
                // 请求：cmd=FS_ADD_DEVICE + 设备块 + bool isIPv6（不混淆，仅头部+包体）
                let enc = service.deviceManager.makeUdpBody(from: from, size: 1024)
                _ = enc.setCmd(LCmd.fsAddDevice)
                _ = enc.putBool(isIPv6)
                try stream.write(enc.getData())
                let header = try stream.readFully(DataEnc.headerLen)
                let dec = DataDec(header)
                let bodyLen = Int(max(0, dec.length))
                let body = bodyLen > 0 ? try stream.readFully(bodyLen) : []
                let reply = DataDec(header + body)
                let devPort = reply.getInt()
                let devIp = reply.getString()
                let devName = reply.getString()
                let devMode = reply.getInt()
                var uuid = reply.getString()
                let dataVersion = reply.getInt()
                let replyIPv6 = reply.getBool()
                if uuid.contains("-") {
                    uuid = String(uuid.split(separator: "-").first ?? Substring(uuid))
                }
                let device = Device(devName: devName, devIP: devIp.isEmpty ? targetIP : devIp, devPort: devPort)
                device.devMode = devMode
                device.uniqueUUid = uuid
                device.dataVersion = dataVersion
                device.isIPv4 = !replyIPv6
                device.canRemove = false
                device.setTime = Int64(Date().timeIntervalSince1970 * 1000)
                service.deviceManager.addDevice(device)
                service.deviceManager.pin(uuid: uuid)
                completion(.success(device))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
