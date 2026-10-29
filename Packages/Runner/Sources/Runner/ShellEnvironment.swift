import Darwin
import Foundation
import Platform

/// 用户登录 shell 的环境。App 从 Finder 启动时 PATH 很短，先用 `-l` 取一次环境，命令才能找到 go、docker、kubectl。
public struct ShellEnvironment: Sendable, Equatable {
    public var shell: String
    public var variables: [String: String]

    public init(shell: String, variables: [String: String]) {
        self.shell = shell
        self.variables = variables
    }

    private static let marker = "__LOCALCICD_ENV__"
    /// 这些变量属于取环境时的那个 shell 进程，不能带给后续命令。
    private static let transient: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_"]

    /// `$SHELL`，取不到时读用户记录，最后用 /bin/zsh。
    public static func loginShell(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        var candidates = [environment["SHELL"]]
        if let record = getpwuid(getuid()), let shell = record.pointee.pw_shell { candidates.append(String(cString: shell)) }
        return candidates.compactMap { $0 }.first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) } ?? "/bin/zsh"
    }

    /// 登录脚本可能往 stdout 打印内容，用标记分隔，只解析标记之后 `env -0` 的输出。
    public static func capture(shell: String = loginShell(), runner: CommandRunner = CommandRunner()) async throws -> ShellEnvironment {
        let script = "printf '\\0\(marker)\\0'; exec /usr/bin/env -0"
        let result = try await runner.capture(Command(executable: shell, arguments: ["-l", "-c", script],
            directory: NSHomeDirectory(), timeout: .seconds(30)), limit: 1 << 20)
        guard result.result.succeeded else {
            throw RunnerError("无法读取登录 shell（\(shell)）的环境，请检查 shell 启动脚本是否报错")
        }
        let fields = result.stdout.split(separator: 0, omittingEmptySubsequences: false)
        guard let start = fields.lastIndex(where: { $0.elementsEqual(marker.utf8) }) else {
            throw RunnerError("登录 shell 的环境输出无法识别")
        }
        var variables: [String: String] = [:]
        for field in fields[(start + 1)...] {
            let entry = String(decoding: field, as: UTF8.self)
            guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else { continue }
            let name = String(entry[..<equals])
            guard !transient.contains(name) else { continue }
            variables[name] = String(entry[entry.index(after: equals)...])
        }
        return ShellEnvironment(shell: shell, variables: variables)
    }

    /// 在 PATH 里查找程序，和终端里输入命令名一样。
    public func which(_ name: String) -> String? {
        for directory in (variables["PATH"] ?? "").split(separator: ":") where directory.hasPrefix("/") {
            let path = "\(directory)/\(name)"
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
