import Foundation

/// 网页端访问令牌 (Android: pojo/Token.java + db/TokenDBUtil.java)
final class LToken {
    var token: String
    var ip: String
    var name: String
    var custom: Bool
    var pass: Int

    init(token: String, ip: String = "", name: String = "", custom: Bool = false, pass: Int = 0) {
        self.token = token
        self.ip = ip
        self.name = name
        self.custom = custom
        self.pass = pass
    }
}

/// token 表：id, ip, name, custom, pass, isdel
final class LTokenDB {
    static let tableName = "token"
    private let db: LDatabase

    init() {
        db = LDatabase(fileName: "token.db")
        db.exec("create table if not exists \(Self.tableName) "
                + "(id VARCHAR(32) primary key,ip VARCHAR(16),name VARCHAR(16),custom INTEGER, pass INTEGER, isdel INTEGER)")
    }

    @discardableResult
    func add(token: String, custom: Bool, pass: Int, ip: String, name: String) -> Bool {
        db.run("insert or ignore into \(Self.tableName) (id, custom, pass, ip, name, isdel) values (?,?,?,?,?,0)",
               [token, custom, pass, ip, name])
    }

    func query(token: String) -> LToken? {
        db.query("select * from \(Self.tableName) where id = ? and isdel = 0", [token], map).first
    }

    func query(customIp: String) -> LToken? {
        db.query("select * from \(Self.tableName) where ip = ? and custom = 1 and isdel = 0", [customIp], map).first
    }

    func queryList() -> [LToken] {
        db.query("select * from \(Self.tableName) where isdel = 0", [], map)
    }

    func setPass(token: String, pass: Int) -> Bool {
        db.run("update \(Self.tableName) set pass = ? where id = ?", [pass, token])
    }

    func setName(token: String, name: String) -> Bool {
        db.run("update \(Self.tableName) set name = ? where id = ?", [name, token])
    }

    func delete(token: String) {
        _ = db.run("delete from \(Self.tableName) where id = ?", [token])
    }

    private func map(_ row: [String: Any]) -> LToken {
        let token = LToken(token: row["id"] as? String ?? "",
                           ip: row["ip"] as? String ?? "",
                           name: row["name"] as? String ?? "",
                           custom: ((row["custom"] as? Int64) ?? 0) != 0,
                           pass: Int((row["pass"] as? Int64) ?? 0))
        return token
    }
}

/// 已同步过的相册资源 (Android: pojo/MediaIdPath.java + db/MediaIdPathDBUtil.java)
final class LMediaIdPath {
    let id: Int64
    let name: String
    let path: String
    let creationTime: Date
    let isReceived: Bool

    init(id: Int64, name: String, path: String, creationTime: Date, isReceived: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.creationTime = creationTime
        self.isReceived = isReceived
    }
}

/// media_id_path 表：id, name, path, creation_time, is_received
final class LMediaIdPathDB {
    static let tableName = "media_id_path"
    private let db: LDatabase

    init() {
        db = LDatabase(fileName: "media_id_path_list.db")
        db.exec("CREATE TABLE IF NOT EXISTS \(Self.tableName) "
                + "(id INTEGER PRIMARY KEY, name TEXT, path TEXT, creation_time TEXT, is_received INTEGER)")
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    @discardableResult
    func add(mediaId: Int64, name: String, path: String, date: Date, isReceived: Bool = false) -> Bool {
        db.run("insert or replace into \(Self.tableName) (id, name, path, creation_time, is_received) values (?,?,?,?,?)",
               [mediaId, name, path, Self.formatter.string(from: date), isReceived])
    }

    func query(mediaId: Int64) -> LMediaIdPath? {
        db.query("select * from \(Self.tableName) where id = ?", [mediaId], map).first
    }

    func queryList() -> [LMediaIdPath] {
        db.query("select * from \(Self.tableName)", [], map)
    }

    func delete(mediaId: Int64) {
        _ = db.run("delete from \(Self.tableName) where id = ?", [mediaId])
    }

    func exists(_ mediaId: Int64) -> Bool {
        db.firstValue("select 1 from \(Self.tableName) where id = ? LIMIT 1", [mediaId]) { _ in true } ?? false
    }

    private func map(_ row: [String: Any]) -> LMediaIdPath {
        let text = row["creation_time"] as? String ?? ""
        let date = Self.formatter.date(from: text) ?? Date()
        return LMediaIdPath(id: (row["id"] as? Int64) ?? 0,
                            name: row["name"] as? String ?? "",
                            path: row["path"] as? String ?? "",
                            creationTime: date,
                            isReceived: ((row["is_received"] as? Int64) ?? 0) != 0)
    }
}

/// 分享下载记录 (Android: db/FileShareDBUtil.java)
final class LFileShareRecord {
    var id: String
    var name: String
    var path: String
    var downloaded: Bool
    var days: Int
    var time: Int64

    init(id: String, name: String, path: String, downloaded: Bool, days: Int, time: Int64) {
        self.id = id
        self.name = name
        self.path = path
        self.downloaded = downloaded
        self.days = days
        self.time = time
    }
}

/// file_share 表：id, name, path, downloaded, days, time, isdel
final class LFileShareDB {
    static let tableName = "file_share"
    private let db: LDatabase

    init() {
        db = LDatabase(fileName: "file_share.db")
        db.exec("create table if not exists \(Self.tableName) "
                + "(id VARCHAR(32) primary key,name VARCHAR(255),path VARCHAR(255),downloaded INTEGER,"
                + "days INTEGER,time INTEGER, isdel INTEGER)")
    }

    @discardableResult
    func addShare(id: String, name: String, path: String, downloaded: Bool, days: Int) -> Bool {
        db.run("insert or replace into \(Self.tableName) (id, name, path, downloaded, days, time, isdel) values (?,?,?,?,?,?,0)",
               [id, name, path, downloaded, days, Int64(Date().timeIntervalSince1970 * 1000)])
    }

    func queryShare(id: String) -> LFileShareRecord? {
        db.query("select * from \(Self.tableName) where id = ? and isdel = 0", [id], map).first
    }

    func queryList() -> [LFileShareRecord] {
        db.query("select * from \(Self.tableName) where isdel = 0 order by time desc", [], map)
    }

    func updateDownloaded(id: String, downloaded: Bool) -> Bool {
        db.run("update \(Self.tableName) set downloaded = ? where id = ?", [downloaded, id])
    }

    func delete(id: String) {
        _ = db.run("update \(Self.tableName) set isdel = 1 where id = ?", [id])
    }

    private func map(_ row: [String: Any]) -> LFileShareRecord {
        LFileShareRecord(id: row["id"] as? String ?? "",
                         name: row["name"] as? String ?? "",
                         path: row["path"] as? String ?? "",
                         downloaded: ((row["downloaded"] as? Int64) ?? 0) != 0,
                         days: Int((row["days"] as? Int64) ?? 0),
                         time: (row["time"] as? Int64) ?? 0)
    }
}

/// 文件夹同步记录 (Android: pojo/FileSyncData.java + db/FileSyncDBUtil.java)
final class LFileSyncData {
    var deviceId: String
    var deviceName: String
    var folderPath: String
    var createTime: Int64
    var name: String

    init(deviceId: String, deviceName: String, folderPath: String, createTime: Int64, name: String) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.folderPath = folderPath
        self.createTime = createTime
        self.name = name
    }
}

/// file_sync_table：device_id, device_name, folder_path, create_time, name
final class LFileSyncDB {
    static let tableName = "file_sync_table"
    private let db: LDatabase

    init() {
        db = LDatabase(fileName: "file_sync_data.db")
        db.exec("create table if not exists \(Self.tableName) "
                + "(device_id VARCHAR(32) primary key, device_name VARCHAR(255), folder_path VARCHAR(255),"
                + " create_time INTEGER, name VARCHAR(255))")
    }

    @discardableResult
    func add(_ data: LFileSyncData) -> Bool {
        db.run("insert or replace into \(Self.tableName) (device_id, device_name, folder_path, create_time, name)"
               + " values (?,?,?,?,?)", [data.deviceId, data.deviceName, data.folderPath, data.createTime, data.name])
    }

    func query(deviceId: String) -> LFileSyncData? {
        db.query("select * from \(Self.tableName) where device_id = ?", [deviceId], map).first
    }

    func queryList() -> [LFileSyncData] {
        db.query("select * from \(Self.tableName)", [], map)
    }

    func delete(deviceId: String) {
        _ = db.run("delete from \(Self.tableName) where device_id = ?", [deviceId])
    }

    private func map(_ row: [String: Any]) -> LFileSyncData {
        LFileSyncData(deviceId: row["device_id"] as? String ?? "",
                      deviceName: row["device_name"] as? String ?? "",
                      folderPath: row["folder_path"] as? String ?? "",
                      createTime: (row["create_time"] as? Int64) ?? 0,
                      name: row["name"] as? String ?? "")
    }
}
