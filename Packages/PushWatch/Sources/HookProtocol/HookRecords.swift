import CryptoKit
import Darwin
import Foundation

public struct HookFailure: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// 安装信息只包含本地路径与身份，不包含远端凭据。
public struct HookInstallation: Codable, Sendable, Equatable {
    public var id: UUID
    public var projectID: Int64
    public var repositoryPath: String
    public var gitExecutable: String
    public var spoolPath: String

    public init(id: UUID = UUID(), projectID: Int64, repositoryPath: String, gitExecutable: String, spoolPath: String) {
        self.id = id
        self.projectID = projectID
        self.repositoryPath = repositoryPath
        self.gitExecutable = gitExecutable
        self.spoolPath = spoolPath
    }
}

/// PID 必须连同内核记录的启动时间比较，避免复用后的其他进程确认旧事件。
public struct HookProcess: Codable, Sendable, Equatable {
    public let pid: Int32
    public let startedSeconds: UInt64
    public let startedMicroseconds: UInt64
    public var key: String { "\(pid)-\(startedSeconds)-\(startedMicroseconds)" }

    public static func inspect(_ pid: Int32) throws -> HookProcess {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
            info.pbi_uid == getuid()
        else { throw HookFailure("无法读取本次 Git 进程的身份") }
        return HookProcess(pid: pid, startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec)
    }

    public var isRunning: Bool { (try? Self.inspect(pid)) == self }
}

public struct HookRef: Codable, Sendable, Equatable {
    public let localRef: String
    public let newSHA: String
    public let remoteRef: String
    public let oldSHA: String
    public var trackingRef: String?

    public static func parse(_ input: Data) throws -> [HookRef] {
        guard input.count <= 1_048_576, let string = String(data: input, encoding: .utf8) else {
            throw HookFailure("推送意图过大或不是有效 UTF-8")
        }
        var refs: [HookRef] = []
        var seen = Set<String>()
        for line in string.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count == 4, validObject(fields[1]), validObject(fields[3]),
                fields[1].count == fields[3].count, validRef(fields[2]),
                !fields[0].unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                seen.insert(fields[2]).inserted
            else { throw HookFailure("推送意图含无效或重复的目标引用") }
            refs.append(HookRef(localRef: fields[0], newSHA: fields[1], remoteRef: fields[2], oldSHA: fields[3]))
        }
        return refs
    }

    public static func validObject(_ value: String) -> Bool {
        [40, 64].contains(value.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func validRef(_ value: String) -> Bool {
        value.hasPrefix("refs/") && !value.hasSuffix("/") && !value.hasSuffix(".") &&
        !value.contains("..") && !value.contains("@{") &&
        !value.unicodeScalars.contains { $0.value <= 32 || $0.value == 127 || "~^:?*[\\".unicodeScalars.contains($0) } &&
        value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
        }
    }
}

public struct HookIntent: Codable, Sendable, Equatable {
    public var id: UUID
    public var installationID: UUID
    public var projectID: Int64
    public var repositoryPath: String
    public var process: HookProcess
    public var remoteName: String
    public var remoteURL: String
    /// 只用于关联同一推送目标；原始凭据不会进入 spool。
    public var remoteFingerprint: String
    public var receivedAt: Date
    public var refs: [HookRef]
    /// 只有确认为直接 git push 且非 dry-run 时，才允许使用退出结果补充确认。
    public var permitsExitConfirmation: Bool?

    public init(installation: HookInstallation, process: HookProcess, remoteName: String, remoteURL: String, refs: [HookRef]) {
        id = UUID()
        installationID = installation.id
        projectID = installation.projectID
        repositoryPath = installation.repositoryPath
        self.process = process
        self.remoteName = Self.sanitizeRemote(remoteName)
        self.remoteURL = Self.sanitizeRemote(remoteURL)
        remoteFingerprint = SHA256.hash(data: Data(remoteURL.utf8)).map { String(format: "%02x", $0) }.joined()
        receivedAt = Date()
        self.refs = refs
        permitsExitConfirmation = nil
    }

    public static func sanitizeRemote(_ value: String) -> String {
        if value.contains("://"), var url = URLComponents(string: value) {
            url.user = nil
            url.password = nil
            url.query = nil
            url.fragment = nil
            return url.string ?? "已隐藏远端地址"
        }
        // SCP 风格地址中的用户名也不保留；普通路径与远端名称保持可读。
        let address = value
        if let at = address.lastIndex(of: "@"), address[at...].contains(":") {
            return String(address[address.index(after: at)...])
        }
        return address
    }
}

public struct HookReceipt: Codable, Sendable, Equatable {
    public var intentID: UUID
    public var process: HookProcess
    public var recordedAt: Date
    public var updates: [Update]

    public struct Update: Codable, Sendable, Equatable {
        public var remoteRef: String
        public var newSHA: String
        public init(remoteRef: String, newSHA: String) { self.remoteRef = remoteRef; self.newSHA = newSHA }
    }

    public init(intentID: UUID, process: HookProcess, updates: [Update]) {
        self.intentID = intentID
        self.process = process
        recordedAt = Date()
        self.updates = updates
    }
}
