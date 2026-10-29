import Foundation

/// App 的全部磁盘路径集中定义在这里，都在 `~/Library/Application Support/<bundle id>` 下。
///
/// 路径中的运行使用本地数字 ID，不使用项目名，避免特殊字符和改名带来的问题。
public struct AppPaths: Sendable, Equatable {
    public static let bundleIdentifier = "io.github.loveyu233.cicdlocal"

    /// `~/Library/Application Support/<bundle id>`
    public let applicationSupport: URL

    public init(applicationSupport: URL) {
        self.applicationSupport = applicationSupport.standardizedFileURL
    }

    /// 当前用户的标准位置。
    public static func standard(
        bundleIdentifier: String = bundleIdentifier,
        fileManager: FileManager = .default
    ) throws -> AppPaths {
        let support = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        return AppPaths(applicationSupport: support.appending(path: bundleIdentifier, directoryHint: .isDirectory))
    }

    /// GRDB 数据库文件（WAL 模式会在旁边生成 `-wal`、`-shm`）。旧版本的 `state.sqlite` 原样保留，不读取也不删除。
    public var database: URL { applicationSupport.appending(path: "localcicd.sqlite", directoryHint: .notDirectory) }

    /// 单实例锁文件，对它执行 `flock(LOCK_EX|LOCK_NB)`。
    public var instanceLock: URL { applicationSupport.appending(path: "instance.lock", directoryHint: .notDirectory) }

    public var logsRoot: URL { directory("logs") }

    /// 运行期间的临时文件，例如替换镜像时写出的 0600 kubeconfig，用完即删。
    public var temporary: URL { directory("tmp") }

    /// spool 根目录。钩子先写 `tmp/`，再原子 rename 到 `new/`。
    public var spoolRoot: URL { directory("spool") }
    public var spoolTmp: URL { spoolRoot.appending(path: "tmp", directoryHint: .isDirectory) }
    public var spoolNew: URL { spoolRoot.appending(path: "new", directoryHint: .isDirectory) }

    /// 钩子脚本所在目录，由仓库配置 `hook.localcicd-*.command` 引用。
    public var hooks: URL { directory("hooks") }

    /// `logs/<运行>/<阶段序号>`：每个阶段一份日志。
    public func stageLog(run: Int64, ordinal: Int) -> URL {
        logsRoot.appending(path: "\(run)/\(ordinal)", directoryHint: .isDirectory)
    }

    /// `logs/<运行>`：删除运行时整体删除。
    public func runLogs(run: Int64) -> URL {
        logsRoot.appending(path: "\(run)", directoryHint: .isDirectory)
    }

    /// 创建全部固定目录，权限 0700（spool 中是钩子写入的数据，不允许其他用户读写）。
    public func createDirectories(fileManager: FileManager = .default) throws {
        for url in [applicationSupport, logsRoot, temporary, spoolRoot, spoolTmp, spoolNew, hooks] {
            try fileManager.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            // 目录已存在时 attributes 不生效，再显式设置一次。
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path(percentEncoded: false))
        }
    }

    /// 判断某个路径是否位于给定根目录之内，用于删除前的保护（只删除本应用创建的内容）。
    public static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return path.count > rootPath.count && Array(path.prefix(rootPath.count)) == rootPath
    }

    private func directory(_ name: String) -> URL {
        applicationSupport.appending(path: name, directoryHint: .isDirectory)
    }
}
