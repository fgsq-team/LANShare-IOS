import Foundation

/// 消息数据库 (Android: db/MesssageDButil.java)
/// 表结构与列顺序与 Android 端保持一致：id, content, messageType, isLeft, header(devMode),
/// userName, toUser, createTime, status, dataVersion, path, length, _index, stateMessage,
/// nextStep(isTransfer), isVideo, videoTime, isDir, isdel
final class LMessageDB {
    static let tableName = "LANShre_Msg"
    private static let messageTime = -1
    private static let message = 1
    private static let messageMedia = 2
    private static let messageFile = 3
    private static let messageGps = 4

    private let db: LDatabase
    /// 分页大小 (Android: Config.PAGE_SIZE)
    static let pageSize = 20

    init() {
        db = LDatabase(fileName: "msg.db")
        db.exec("""
        create table if not exists \(Self.tableName) (
            id VARCHAR(32) primary key, content text, messageType INTEGER, isLeft INTEGER,
            header INTEGER, userName text, toUser text, createTime INTEGER, status INTEGER,
            dataVersion INTEGER, path VARCHAR(255), length INTEGER, _index INTEGER,
            stateMessage text, nextStep INTEGER, isVideo INTEGER, videoTime VARCHAR(19),
            isDir INTEGER, isdel INTEGER)
        """)
    }

    // MARK: - 写入

    func add(_ content: MessageContent) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let values = rowValues(content, createTime: now)
        _ = db.run("insert or replace into \(Self.tableName) values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", values)
    }

    func update(_ content: MessageContent) {
        let values = rowValues(content, createTime: Int64(content.createTime.timeIntervalSince1970 * 1000))
        // 未绑定的 ? 会当成 NULL，where id = NULL 匹配不到任何行，所以末尾还要补上主键
        var args = Array(values.dropFirst())
        args.append(content.id)
        _ = db.run("""
        update \(Self.tableName) set content=?, messageType=?, isLeft=?, header=?, userName=?, toUser=?,
        createTime=?, status=?, dataVersion=?, path=?, length=?, _index=?, stateMessage=?, nextStep=?,
        isVideo=?, videoTime=?, isDir=?, isdel=? where id=?
        """, args)
    }

    func addList(_ contents: [MessageContent]) {
        contents.forEach { add($0) }
    }

    func exists(_ id: String) -> Bool {
        db.firstValue("select 1 from \(Self.tableName) where id = ? LIMIT 1", [id]) { _ in true } ?? false
    }

    /// V5 续传：命中同一条记录时更新而不新增
    func addOrUpdateList(_ contents: [MessageContent]) {
        for content in contents {
            if exists(content.id) { update(content) } else { add(content) }
        }
    }

    /// 软删除
    func delete(id: String) {
        _ = db.run("update \(Self.tableName) set isdel = 1 where id = ?", [id])
    }

    func delete(ids: [String]) {
        ids.forEach { delete(id: $0) }
    }

    func deleteAll() {
        _ = db.run("update \(Self.tableName) set isdel = 1 where isdel = 0")
    }

    // MARK: - 查询

    func lastMessageTime() -> Int64 {
        db.firstValue("select createTime from \(Self.tableName) where isdel = 0 and messageType = -1 "
                      + "ORDER BY createTime DESC LIMIT 1") { row in
            (row["createTime"] as? Int64)
        } ?? -1
    }

    func queryByBindId(_ bindId: String) -> String? {
        db.firstValue("select id from \(Self.tableName) where isdel = 0 and messageType = -1 and toUser = ? LIMIT 1",
                      [bindId]) { row in row["id"] as? String }
    }

    /// 分页：pageNum 从最旧一页开始，最后一页在前 (与 Android 计算方式一致)
    func query(pageSize: Int = LMessageDB.pageSize, pageNum: Int = 0) -> (list: [MessageContent], totalPages: Int) {
        let totalCount = db.firstValue("SELECT COUNT(1) FROM \(Self.tableName) WHERE isdel = 0") { row in
            (row["COUNT(1)"] as? Int64).map { Int($0) }
        } ?? 0
        let totalPages = Int(ceil(Double(totalCount) / Double(pageSize)))
        let offset = (totalPages - pageNum - 1) * pageSize
        if offset < 0 { return ([], totalPages) }
        let rows = db.query("SELECT * FROM \(Self.tableName) WHERE isdel = 0 ORDER BY createTime ASC LIMIT ? OFFSET ?",
                            [pageSize, offset], { $0 })
        return (decode(rows), totalPages)
    }

    // MARK: - 行映射

    private func rowValues(_ content: MessageContent, createTime: Int64) -> [Any?] {
        var path: Any?
        var length: Any?
        var index: Any?
        var stateMessage: Any?
        var nextStep: Any?
        var isVideo: Any?
        var videoTime: Any?
        var isDir = false
        var type = content.messageType

        if let file = content as? MessageFileContent {
            path = file.path.isEmpty ? nil : LFileStore.stored(file.path)
            length = file.length
            index = file.index
            stateMessage = file.stateMessage
            nextStep = file.isTransfer
            if let media = file as? MessageMediaContent {
                type = Self.messageMedia
                isVideo = media.isVideo
                videoTime = media.videoTime
            } else if file.fileType == MessageFileContent.fileTypeFolder {
                type = Self.messageFile
                isDir = true
            } else {
                type = Self.messageFile
            }
        } else if content is MessageGPSContent {
            type = Self.messageGps
        } else if let time = content as? MessageTimeContent {
            type = Self.messageTime
            return [content.id, nil, type, nil, nil, nil, time.bindId, createTime, nil, nil,
                    nil, nil, nil, nil, nil, nil, nil, false, false]
        } else {
            type = Self.message
        }
        return [content.id, content.content, type, content.isLeft, content.devMode, content.userName,
                content.toUser, createTime, content.status, content.dataVersion, path, length, index,
                stateMessage, nextStep, isVideo, videoTime, isDir, false]
    }

    private func decode(_ rows: [[String: Any]]) -> [MessageContent] {
        rows.compactMap { row -> MessageContent? in
            let id = row["id"] as? String ?? MessageContent.newId()
            let content = row["content"] as? String ?? ""
            let type = Int((row["messageType"] as? Int64) ?? 1)
            let isLeft = ((row["isLeft"] as? Int64) ?? 1) != 0
            let devMode = Int32((row["header"] as? Int64) ?? Int64(DevMode.unknow.rawValue))
            let userName = row["userName"] as? String ?? ""
            let toUser = row["toUser"] as? String ?? ""
            let status = Int((row["status"] as? Int64) ?? Int64(MessageStatus.success))
            let dataVersion = Int32((row["dataVersion"] as? Int64) ?? Int64(LConst.dataVersion))
            let millis = (row["createTime"] as? Int64).map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date()

            func fill(_ item: MessageContent) -> MessageContent {
                item.id = id
                item.content = content
                item.isLeft = isLeft
                item.devMode = devMode
                item.userName = userName
                item.toUser = toUser
                item.status = status
                item.dataVersion = dataVersion
                item.createTime = millis
                return item
            }

            /// 状态修正必须排在 fill 之后，否则会被数据库里的状态覆盖
            func decodeFile(_ item: MessageFileContent, _ row: [String: Any]) -> MessageContent {
                applyFile(item, row)
                fill(item)
                fixStatusAfterLoad(item)
                return item
            }

            switch type {
            case Self.messageTime:
                let item = MessageTimeContent()
                item.id = id
                item.bindId = toUser
                item.toUser = toUser
                item.createTime = millis
                return item
            case Self.messageMedia:
                let item = MessageMediaContent(isVideo: ((row["isVideo"] as? Int64) ?? 0) != 0,
                                              videoTime: row["videoTime"] as? String ?? "")
                return decodeFile(item, row)
            case Self.messageFile:
                let item: MessageFileContent = ((row["isDir"] as? Int64) ?? 0) != 0
                    ? MessageFolderContent() : MessageFileContent()
                return decodeFile(item, row)
            case Self.messageGps:
                let item = MessageGPSContent.from(jsonString: content) ?? MessageGPSContent()
                return fill(item)
            default:
                return fill(MessageTextContent())
            }
        }
    }

    /// 载入历史消息时的状态修正 (Android: queryMessage 内的 IN/SUCCESS 复检)
    private func fixStatusAfterLoad(_ file: MessageFileContent) {
        if file.status & MessageStatus.inProgress != 0 {
            file.status = MessageStatus.error
            file.stateMessage = "未完成"
        } else if file.status & MessageStatus.success != 0, !file.path.isEmpty,
                  FileManager.default.isReadableFile(atPath: file.path),
                  !FileManager.default.fileExists(atPath: file.path) {
            file.status = MessageStatus.error | MessageStatus.fileNotExist
            file.stateMessage = "文件已被删除"
        }
    }

    private func applyFile(_ item: MessageFileContent, _ row: [String: Any]) {
        item.path = LFileStore.resolved(row["path"] as? String ?? "")
        item.length = (row["length"] as? Int64) ?? 0
        item.index = Int((row["_index"] as? Int64) ?? 0)
        item.stateMessage = row["stateMessage"] as? String ?? ""
        item.isTransfer = ((row["nextStep"] as? Int64) ?? 1) != 0
        // 主键 id 即 fileId，保证续传记录可复用
        item.fileId = row["id"] as? String ?? ""
        if item.fileType != MessageFileContent.fileTypeFolder,
           let media = item as? MessageMediaContent {
            item.fileType = media.isVideo ? MessageFileContent.fileTypeVideo : MessageFileContent.fileTypeImage
        }
    }
}
