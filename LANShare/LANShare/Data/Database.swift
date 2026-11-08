import Foundation
import SQLite3

/// SQLite 封装 (Android: SQLiteOpenHelper)
final class LDatabase {
    static let openFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX

    private(set) var handle: OpaquePointer?
    private let gate = NSLock()
    let path: String

    init(fileName: String) {
        let dir = LDatabase.storageDirectory()
        path = (dir as NSString).appendingPathComponent(fileName)
        guard sqlite3_open_v2(path, &handle, LDatabase.openFlags, nil) == SQLITE_OK else {
            LLog.error("open db failed: \(path)")
            handle = nil
            return
        }
        _ = sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
    }

    static func storageDirectory() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("LANShare", isDirectory: true).path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func close() {
        gate.lock()
        if let handle { sqlite3_close_v2(handle) }
        self.handle = nil
        gate.unlock()
    }

    deinit { close() }

    // MARK: - 执行

    @discardableResult
    func exec(_ sql: String) -> Bool {
        gate.lock()
        defer { gate.unlock() }
        var err: UnsafeMutablePointer<Int8>?
        let code = sqlite3_exec(handle, sql, nil, nil, &err)
        if code != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "\(code)"
            LLog.error("exec failed: \(msg) sql=\(sql)")
            sqlite3_free(err)
            return false
        }
        return true
    }

    /// 写入类语句
    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) -> Bool {
        gate.lock()
        defer { gate.unlock() }
        return eachRow(sql, args) { _ in () }.0
    }

    /// 查询类语句，逐行映射
    func query<T>(_ sql: String, _ args: [Any?] = [], _ row: @escaping ([String: Any]) -> T) -> [T] {
        gate.lock()
        defer { gate.unlock() }
        return eachRow(sql, args) { stmt in row(LDatabase.rowDict(stmt)) }.1
    }

    func firstValue<T>(_ sql: String, _ args: [Any?] = [], _ map: @escaping ([String: Any]) -> T?) -> T? {
        query(sql, args) { map($0) }.compactMap { $0 }.first
    }

    private static func rowDict(_ stmt: OpaquePointer?) -> [String: Any] {
        var dict: [String: Any] = [:]
        let count = Int(sqlite3_column_count(stmt))
        for i in 0..<count {
            let name = String(cString: sqlite3_column_name(stmt, Int32(i)))
            if let value = LDatabase.columnValue(stmt, i) {
                dict[name] = value
            }
        }
        return dict
    }

    private func eachRow<T>(_ sql: String, _ args: [Any?], _ body: (OpaquePointer) -> T) -> (Bool, [T]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            LLog.error("prepare failed: \(String(cString: sqlite3_errmsg(handle))) sql=\(sql)")
            return (false, [])
        }
        defer { sqlite3_finalize(stmt) }
        let needed = Int(sqlite3_bind_parameter_count(stmt))
        if needed != args.count {
            // 少绑定的 ? 会被 SQLite 当成 NULL，UPDATE/INSERT 静默不生效
            LLog.error("bind count \(args.count) != placeholders \(needed): \(sql)")
        }
        for (i, arg) in args.enumerated() {
            bind(arg, to: stmt, index: Int32(i + 1))
        }
        var rows: [T] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            rows.append(body(stmt))
            result = sqlite3_step(stmt)
        }
        if result != SQLITE_DONE {
            LLog.error("step failed: \(String(cString: sqlite3_errmsg(handle))) sql=\(sql)")
            return (false, rows)
        }
        return (true, rows)
    }

    private func bind(_ value: Any?, to stmt: OpaquePointer?, index: Int32) {
        switch value {
        case .none, is NSNull:
            sqlite3_bind_null(stmt, index)
        case let v as Bool:
            sqlite3_bind_int(stmt, index, v ? 1 : 0)
        case let v as Int:
            sqlite3_bind_int64(stmt, index, Int64(v))
        case let v as Int32:
            sqlite3_bind_int64(stmt, index, Int64(v))
        case let v as Int64:
            sqlite3_bind_int64(stmt, index, v)
        case let v as Double:
            sqlite3_bind_double(stmt, index, v)
        case let v as String:
            sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
        case let v as [UInt8]:
            v.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
        case let v as Data:
            v.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
        default:
            sqlite3_bind_null(stmt, index)
        }
    }

    static func columnValue(_ stmt: OpaquePointer?, _ i: Int) -> Any? {
        switch sqlite3_column_type(stmt, Int32(i)) {
        case SQLITE_INTEGER: return Int64(sqlite3_column_int64(stmt, Int32(i)))
        case SQLITE_FLOAT: return sqlite3_column_double(stmt, Int32(i))
        case SQLITE_TEXT: return String(cString: sqlite3_column_text(stmt, Int32(i)))
        case SQLITE_BLOB:
            let len = Int(sqlite3_column_bytes(stmt, Int32(i)))
            guard let ptr = sqlite3_column_blob(stmt, Int32(i)), len > 0 else { return [UInt8]() }
            return [UInt8](UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: len))
        default: return nil
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
