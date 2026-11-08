import Foundation
import os

/// 简易日志 (Android: LLog + slf4j)
enum LLog {
    private static let log = Logger(subsystem: "fgsqw.lanshare", category: "LANShare")
    static var enabled = true

    static func debug(_ msg: @autoclosure () -> String) {
        guard enabled else { return }
        let text = msg()
        log.debug("\(text, privacy: .public)")
    }

    static func error(_ msg: @autoclosure () -> String) {
        let text = msg()
        log.error("\(text, privacy: .public)")
    }

    static func info(_ msg: @autoclosure () -> String) {
        let text = msg()
        log.info("\(text, privacy: .public)")
    }
}

/// 后台任务队列 (Android: ThreadUtils.runThread + ExecutorService)
enum LThread {
    /// IO 任务：阻塞式 socket 读写
    static let io = DispatchQueue(label: "fgsqw.lanshare.io", qos: .utility,
                                  attributes: .concurrent, autoreleaseFrequency: .workItem)
    /// 单串行的任务队列，用于同设备并发控制
    static func serial(_ name: String) -> DispatchQueue {
        DispatchQueue(label: "fgsqw.lanshare.\(name)", qos: .utility)
    }

    static func run(_ block: @escaping () -> Void) {
        io.async(execute: block)
    }

    static func main(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    static func sleep(seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }
}

/// 按 key 串行化的锁池 (Android: utils/StringLockManager.java)
final class StringLockManager {
    static let shared = StringLockManager()
    private let locks: NSMapTable<NSString, NSLock> = NSMapTable(keyOptions: .copyIn, valueOptions: .strongMemory)
    private let gate = NSLock()

    func lock(for key: String) -> NSLock {
        gate.lock()
        defer { gate.unlock() }
        let k = key as NSString
        if let existing = locks.object(forKey: k) { return existing }
        let lock = NSLock()
        locks.setObject(lock, forKey: k)
        return lock
    }
}
