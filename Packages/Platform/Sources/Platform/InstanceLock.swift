import Darwin
import Foundation

/// 单实例锁：对锁文件执行 `flock(LOCK_EX|LOCK_NB)`（同一数据目录只允许一个 App 实例）。
///
/// 锁跟随打开的文件描述，进程退出（包括崩溃）时由内核自动释放，不会留下陈旧锁。
/// 拿不到锁时由 App 激活已有实例并退出，激活逻辑在 App 层。
public final class InstanceLock: Sendable {
    public let url: URL
    private let descriptor: Int32

    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = descriptor
    }

    /// 尝试获取锁。已有实例持有时返回 nil；其他错误抛出。
    public static func acquire(at url: URL) throws -> InstanceLock? {
        let path = url.path(percentEncoded: false)
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw InstanceLockError.openFailed(path: path, errno: errno) }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return nil }
            throw InstanceLockError.lockFailed(path: path, errno: code)
        }

        // 写入当前 PID，只用于诊断；判断是否有实例只看 flock。
        let pid = "\(getpid())\n"
        _ = ftruncate(fd, 0)
        _ = pid.withCString { pwrite(fd, $0, strlen($0), 0) }
        return InstanceLock(url: url, descriptor: fd)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

public enum InstanceLockError: Error, Equatable, CustomStringConvertible {
    case openFailed(path: String, errno: Int32)
    case lockFailed(path: String, errno: Int32)

    public var description: String {
        switch self {
        case .openFailed(let path, let code): "无法打开单实例锁文件 \(path)：\(String(cString: strerror(code)))"
        case .lockFailed(let path, let code): "无法锁定单实例锁文件 \(path)：\(String(cString: strerror(code)))"
        }
    }
}
