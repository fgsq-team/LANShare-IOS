import Foundation

/// 接收端 (Android: service/version/five/FileServerV5.java + four/FileServer.java)
/// V5 走 .part 分段续传，V4 直接落地；两者共用同一条命令分发链。
final class LFileServer {
    weak var service: LANService?
    private let chunkSize = 1024 * 1024

    init(service: LANService?) {
        self.service = service
        ResumeStore.cleanupExpired()
    }

    /// 版本握手完成后的命令分发
    func handleVersion(device: Device, stream: LTcpStream, useV5: Bool) {
        do {
            let cmd = try stream.readInt()
            switch cmd {
            case LCmd.fsShareFile:
                try handleFileShare(device: device, stream: stream, useV5: useV5)
            case LCmd.fsMessage:
                try LSyncFeatureHandler.handleMessage(service: service, device: device, stream: stream)
            case LCmd.fsGetNoSyncMedia:
                try LSyncFeatureHandler.handleMediaSync(service: service, stream: stream)
            case LCmd.fsDrawSyncRequest:
                try LSyncFeatureHandler.handleDrawSync(service: service, device: device, stream: stream)
            default:
                LLog.debug("V\(useV5 ? 5 : 4) unknown cmd: \(cmd)")
                stream.close()
            }
        } catch {
            LLog.debug("handleVersion closed: \(error)")
            stream.close()
        }
    }

    // MARK: - 文件传输入口

    private func handleFileShare(device: Device, stream: LTcpStream, useV5: Bool) throws {
        let encData = try stream.readBoolean()
        guard let json = try stream.readString(), let data = json.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let filesJson = request["files"] as? [[String: Any]] else {
            stream.close()
            return
        }
        let files = parseFiles(filesJson, from: device)
        let transfer = LFileTransfer(fromDevice: device, files: files)
        // 偏量表在这里一次算定：发送端按它跳过字节，接收端按它决定读多少，
        // 两边不同源就会一个不发一个等，多文件时表现为进度条永久卡住。
        if useV5 {
            transfer.resumeMap = buildResumeMap(files)
        }

        let accept: (Bool) -> Void = { [weak self] isAgree in
            LThread.run {
                guard let self else { return }
                do {
                    try stream.writeInt(isAgree ? LCmd.fsAgree : LCmd.fsNotAgree)
                    guard isAgree else {
                        for file in files { self.finish(file, success: false) }
                        stream.close()
                        return
                    }
                    if useV5 {
                        try stream.writeString(self.resumeMapJson(transfer.resumeMap))
                    }
                    try self.startReceiveFile(transfer: transfer, stream: stream, encData: encData, useV5: useV5)
                } catch {
                    LLog.error("receive failed: \(error)")
                    stream.close()
                }
            }
        }

        if LSettings.shared.notRecvDialog {
            accept(true)
        } else {
            service?.requestReceiveApproval(files: files) { isAgree in accept(isAgree) }
        }
    }

    private func parseFiles(_ array: [[String: Any]], from device: Device) -> [MessageFileContent] {
        var files: [MessageFileContent] = []
        for entry in array {
            let type = (entry["fileType"] as? NSNumber)?.intValue ?? MessageFileContent.fileTypeFile
            let length = (entry["length"] as? NSNumber)?.int64Value ?? 0
            let name = entry["name"] as? String ?? ""
            let fileId = entry["fileId"] as? String ?? ""
            let file: MessageFileContent
            if type == MessageFileContent.fileTypeFolder {
                let folder = MessageFolderContent()
                folder.content = name
                folder.length = length
                if let children = entry["children"] as? [[String: Any]] {
                    folder.children = children.map { child in
                        let c = MessageFileContent(
                            fileId: child["fileId"] as? String ?? "",
                            fileType: (child["fileType"] as? NSNumber)?.intValue ?? MessageFileContent.fileTypeFile,
                            name: child["name"] as? String ?? "",
                            length: (child["length"] as? NSNumber)?.int64Value ?? 0)
                        return c
                    }
                    folder.fileCount = folder.children.count
                }
                file = folder
            } else if type == MessageFileContent.fileTypeImage || type == MessageFileContent.fileTypeVideo {
                let media = MessageMediaContent(isVideo: type == MessageFileContent.fileTypeVideo,
                                                videoTime: entry["videoTime"] as? String ?? "")
                media.content = name
                media.length = length
                media.isGif = (entry["gif"] as? NSNumber)?.boolValue ?? false
                file = media
            } else {
                file = MessageFileContent(fileId: fileId, fileType: type, name: name, length: length)
            }
            file.isLeft = true
            file.userName = device.devName
            file.toUser = LSettings.shared.devName
            file.devMode = device.devMode
            file.status = MessageStatus.inProgress
            file.fileId = fileId
            // 接收端用发送端下发的稳定 fileId 作为记录主键，保证续传复用同一条记录
            file.id = fileId.isEmpty ? MessageContent.newId() : fileId
            files.append(file)
        }
        return files
    }

    func startReceiveFile(transfer: LFileTransfer, stream: LTcpStream, encData: Bool, useV5: Bool) throws {
        service?.showProgress(transfer.files)
        for file in transfer.files {
            file.cancelStream = stream
        }
        defer {
            // 传输结束就不再持有连接，fd 才能真正释放
            for file in transfer.files {
                file.cancelStream = nil
            }
            stream.close()
        }
        do {
            for file in transfer.files {
                if file.fileType == MessageFileContent.fileTypeFolder, let folder = file as? MessageFolderContent {
                    try handleFolder(stream: stream, transfer: transfer, folder: folder, encData: encData, useV5: useV5)
                } else {
                    try handleFile(stream: stream, transfer: transfer, file: file, encData: encData, useV5: useV5)
                }
            }
        } catch {
            // 中断后剩余文件必须落到终态，否则进度条会一直停在「传输中」
            for file in transfer.files where !file.isFinal {
                finish(file, success: false)
            }
            throw error
        }
    }

    // MARK: - 单文件

    private func handleFile(stream: LTcpStream, transfer: LFileTransfer, file: MessageFileContent,
                            encData: Bool, useV5: Bool) throws {
        let length = file.length
        let resumable = useV5 && Self.isResumable(file.fileType) && !file.fileId.isEmpty
        if !resumable {
            try receiveDirect(stream: stream, transfer: transfer, file: file, encData: encData)
            return
        }
        if length <= 0 {
            let dst = classifiedFile(file)
            touch(dst)
            file.path = dst
            finish(file, success: true)
            return
        }
        let part = ResumeStore.filePart(file.fileId)
        let offset = min(max(0, transfer.resumeMap[file.fileId] ?? 0), length)
        var received: Int64
        if offset >= length {
            received = length
        } else {
            let writer = try ResumeStore.openAppendWriter(part, offset: offset)
            defer { writer.close() }
            received = try recvStream(stream: stream, transfer: transfer, out: writer, finalSize: length,
                                      base: file, item: file, startOffset: offset, progressBase: offset,
                                      encData: encData)
        }
        if received < length {
            finish(file, success: false)
            return
        }
        file.path = ResumeStore.finalizePart(part, to: classifiedFile(file))
        finish(file, success: true)
    }

    /// 不可续传：直接写入最终文件(V4 行为)
    private func receiveDirect(stream: LTcpStream, transfer: LFileTransfer, file: MessageFileContent,
                               encData: Bool) throws {
        let filePath = classifiedFile(file)
        let length = file.length
        var total: Int64 = 0
        if length > 0 {
            let writer = try LFileWriter(path: filePath, append: false)
            defer { writer.close() }
            total = try recvStream(stream: stream, transfer: transfer, out: writer, finalSize: length,
                                   base: file, item: file, startOffset: 0, progressBase: 0, encData: encData)
            file.path = filePath
        } else {
            touch(filePath)
            file.path = filePath
        }
        finish(file, success: total == length)
    }

    // MARK: - 文件夹

    private func handleFolder(stream: LTcpStream, transfer: LFileTransfer, folder: MessageFolderContent,
                              encData: Bool, useV5: Bool) throws {
        guard useV5, !folder.fileId.isEmpty else {
            try handleFolderDirect(stream: stream, transfer: transfer, folder: folder, encData: encData)
            return
        }
        let folderId = folder.fileId
        let fileSize = folder.length
        let children = folder.children
        let stage = ResumeStore.folderStageDir(folderId)
        var finalDir = ResumeStore.readTarget(stage) ?? ""
        if finalDir.isEmpty {
            let path = FileUtil.classifyFile(base: LSettings.shared.fileSavePath, category: LConst.folderLabel)
            finalDir = FileUtil.avoidDuplication((path as NSString).appendingPathComponent(folder.name))
            try? FileManager.default.createDirectory(atPath: finalDir, withIntermediateDirectories: true)
            ResumeStore.writeTarget(stage, finalDir)
        }
        var total: Int64 = 0
        var failed = false
        for child in children {
            if child.length <= 0 {
                let dst = (finalDir as NSString).appendingPathComponent(child.name)
                touch(dst)
                continue
            }
            let childPart = ResumeStore.childPart(folderFileId: folderId, childFileId: child.fileId)
            let offset = min(max(0, transfer.resumeMap[child.fileId] ?? 0), child.length)
            var received: Int64
            if offset >= child.length {
                received = child.length
            } else {
                let writer = try ResumeStore.openAppendWriter(childPart, offset: offset)
                defer { writer.close() }
                received = try recvStream(stream: stream, transfer: transfer, out: writer, finalSize: fileSize,
                                          base: folder, item: child, startOffset: offset,
                                          progressBase: total + offset, encData: encData)
            }
            if received < 0 {
                failed = true
                break
            }
            if received >= child.length, ResumeStore.fileSize(childPart) >= child.length {
                ResumeStore.movePartToFinal(childPart, finalDir: finalDir, relativeName: child.name)
            }
            total += received
        }
        folder.path = finalDir
        let success = !failed && total == fileSize
        if success {
            ResumeStore.deleteDir(stage)
        }
        finish(folder, success: success)
    }

    private func handleFolderDirect(stream: LTcpStream, transfer: LFileTransfer, folder: MessageFolderContent,
                                    encData: Bool) throws {
        let fileSize = folder.length
        let path = FileUtil.classifyFile(base: LSettings.shared.fileSavePath, category: LConst.folderLabel)
        let finalDir = FileUtil.avoidDuplication((path as NSString).appendingPathComponent(folder.name))
        try? FileManager.default.createDirectory(atPath: finalDir, withIntermediateDirectories: true)
        var total: Int64 = 0
        for child in folder.children {
            let dst = FileUtil.avoidDuplication((finalDir as NSString).appendingPathComponent(child.name))
            try? FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            if child.length <= 0 {
                touch(dst)
                continue
            }
            let writer = try LFileWriter(path: dst, append: false)
            var received: Int64 = 0
            do {
                received = try recvStream(stream: stream, transfer: transfer, out: writer, finalSize: fileSize,
                                          base: folder, item: child, startOffset: 0, progressBase: total,
                                          encData: encData)
            } catch {
                writer.close()
                throw error
            }
            writer.close()
            if received < 0 {
                total = 0
                break
            }
            total += received
        }
        folder.path = finalDir
        finish(folder, success: total == fileSize)
    }

    // MARK: - 流接收核心

    /// 返回该文件完成的绝对字节数，失败返回 -1
    private func recvStream(stream: LTcpStream, transfer: LFileTransfer, out: LFileWriter, finalSize: Int64,
                            base: MessageFileContent, item: MessageFileContent, startOffset: Int64,
                            progressBase: Int64, encData: Bool) throws -> Int64 {
        var fileIndex = startOffset
        var sent: Int64 = 0
        var targetSize = item.length - startOffset
        var lastProgress = 0
        while true {
            if !item.isTransfer && !base.isTransfer {
                return -1
            }
            let length = try stream.readInt()
            if length <= 0 {
                LLog.debug("recv cmd error: \(length)")
                return -1
            }
            let chunk = try stream.readFully(Int(length))
            if chunk.isEmpty { break }
            var buffer = chunk
            if encData {
                LCrypto.maskDecData(&buffer, len: buffer.count, off: 0, index: fileIndex)
            }
            try out.write(buffer)
            fileIndex += Int64(buffer.count)
            sent += Int64(buffer.count)
            targetSize -= Int64(buffer.count)
            let progress = finalSize > 0 ? Int((progressBase + sent) * 100 / finalSize) : 100
            if progress != lastProgress {
                lastProgress = progress
                base.progress = progress
                service?.progressUpdate(base)
            }
            if targetSize <= 0 { break }
        }
        return fileIndex == item.length ? fileIndex : -1
    }

    // MARK: - 续传偏量表

    /// 续传偏量表(fileId -> 已完成字节)，接收端回复给发送端并自用，二者必须同源
    private func buildResumeMap(_ files: [MessageFileContent]) -> [String: Int64] {
        var map: [String: Int64] = [:]
        for file in files {
            let type = file.fileType
            let fileId = file.fileId
            guard Self.isResumable(type), !fileId.isEmpty else { continue }
            if type == MessageFileContent.fileTypeFolder, let folder = file as? MessageFolderContent {
                let stage = ResumeStore.folderStageDir(fileId)
                let finalDir = ResumeStore.readTarget(stage) ?? ""
                for child in folder.children where child.length > 0 && !child.fileId.isEmpty {
                    map[child.fileId] = resumeOffset(total: child.length,
                                                     finalPath: finalDir.isEmpty ? nil :
                                                        (finalDir as NSString).appendingPathComponent(child.name),
                                                     partPath: ResumeStore.childPart(folderFileId: fileId,
                                                                                     childFileId: child.fileId))
                }
            } else {
                // 顶层文件只认分段：Android 每次发送都换新的 fileId，重复发送就是要落地成新副本
                map[fileId] = ResumeStore.readOffset(ResumeStore.filePart(fileId), total: file.length)
            }
        }
        return map
    }

    /// 单个条目已完成字节：最终文件已就位则整份视为完成，否则取分段已写入量
    private func resumeOffset(total: Int64, finalPath: String?, partPath: String) -> Int64 {
        if total > 0, let finalPath, FileManager.default.fileExists(atPath: finalPath),
           ResumeStore.fileSize(finalPath) == total {
            return total
        }
        return ResumeStore.readOffset(partPath, total: total)
    }

    private func resumeMapJson(_ map: [String: Int64]) -> String {
        // 只下发非零偏移，与 Android 的包体一致
        let encoded = map.filter { $0.value > 0 }.mapValues { NSNumber(value: $0) }
        guard let data = try? JSONSerialization.data(withJSONObject: encoded),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    // MARK: - 辅助

    private func classifiedFile(_ fileItem: MessageFileContent) -> String {
        let dir = FileUtil.classifyFile(base: LSettings.shared.fileSavePath,
                                        category: LConst.category(for: fileItem.name))
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return FileUtil.avoidDuplication((dir as NSString).appendingPathComponent(fileItem.name))
    }

    private func touch(_ path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: Data())
        }
    }

    static func isResumable(_ fileType: Int) -> Bool {
        switch fileType {
        case MessageFileContent.fileTypeImage, MessageFileContent.fileTypeVideo,
             MessageFileContent.fileTypeAudio, MessageFileContent.fileTypeApk,
             MessageFileContent.fileTypeFile, MessageFileContent.fileTypeFolder:
            return true
        default:
            return false
        }
    }

    private func finish(_ file: MessageFileContent, success: Bool) {
        if file.isFinal { return }
        // 状态位同步写入，进度条关闭再回主线程
        if success {
            file.status = MessageStatus.success
            file.stateMessage = "接收成功"
            file.progress = 100
            if let media = file as? MessageMediaContent, media.mediaId > -1 {
                service?.mediaIdPathDB.add(mediaId: media.mediaId, name: media.name,
                                           path: media.path, date: Date())
            }
        } else {
            file.status = MessageStatus.error
            file.stateMessage = "接收失败"
        }
        LThread.main { [weak self] in
            self?.service?.closeProgress(file)
        }
    }
}
