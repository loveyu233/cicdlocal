import Foundation
import LogKit
import Platform

/// 一个阶段的结果。`message` 是显示在界面上的说明，例如失败的原因；为 nil 时用默认文字。
public struct StageResult: Sendable, Equatable {
    public var succeeded: Bool
    public var message: String?

    public init(succeeded: Bool, message: String? = nil) {
        self.succeeded = succeeded
        self.message = message
    }

    public static func failed(_ message: String) -> StageResult { StageResult(succeeded: false, message: message) }
}

/// 命令输出的末尾（stdout 和 stderr 合在一起），用来在失败时找出最像原因的一行。
actor OutputTail {
    private let limit: Int
    private var data = Data()

    init(limit: Int = 64 * 1_024) { self.limit = limit }

    func append(_ chunk: Data) {
        data.append(chunk)
        if data.count > limit { data = Data(data.suffix(limit)) }
    }

    func keyLine() -> String? { Self.keyLine(in: String(decoding: data, as: UTF8.self)) }

    /// panic 的第一行；否则最后一行含 error、fatal、exception、failed 的；否则最后一个非空行。去掉终端颜色，最多 300 个字符。
    static func keyLine(in text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { line in
            line.replacing(#/\x1B\[[0-9;?]*[ -\/]*[@-~]/#, with: "")
                .filter { !($0.unicodeScalars.first.map { $0.properties.generalCategory == .control } ?? false) }
                .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        let line = lines.first { $0.hasPrefix("panic:") }
            ?? lines.last { $0.range(of: "error|fatal|exception|failed", options: [.regularExpression, .caseInsensitive]) != nil }
            ?? lines.last
        return line.map { String($0.prefix(300)) }
    }
}

/// 在项目目录里按顺序执行命令，和在终端里 cd 进项目后手动执行一样。输出写入阶段日志，任一命令失败即停止。
public struct StageRunner: Sendable {
    public let root: URL
    public let shell: ShellEnvironment
    /// 每条命令额外得到的 CICD_* 变量。
    public let variables: [String: String]
    public var commandTimeout: Duration = .seconds(3_600)
    private let runner = CommandRunner()

    public init(root: URL, shell: ShellEnvironment, variables: [String: String]) {
        self.root = root
        self.shell = shell
        self.variables = variables
    }

    /// 测试阶段：逐条执行 test 命令。
    public func test(_ commands: [String], log: JobLogStore) async throws -> Bool {
        for command in commands {
            guard try await run(command, log: log) else { return false }
        }
        return true
    }

    /// 构建推送阶段：dockerfile 形式执行 docker build + docker push；command 形式原样执行。
    public func build(_ plan: RunPlan.Image, log: JobLogStore) async throws -> Bool {
        switch plan.build {
        case .command(let command):
            return try await run(command, log: log)
        case .dockerfile(let path, let platform):
            guard let dockerfile = contained(path) else {
                try await log.message("dockerfile 不存在或指向项目外：\(path)")
                return false
            }
            guard let docker = shell.which("docker") else {
                try await log.message("在登录 shell 的 PATH 里找不到 docker，请确认在终端里能直接运行 docker")
                return false
            }
            let platformArguments = platform.map { ["--platform", $0] } ?? []
            let relative = String(dockerfile.path.dropFirst(resolvedRoot.path.count + 1))
            guard try await execute(docker, ["build"] + platformArguments + ["-f", relative, "-t", plan.image, "."], log: log) else {
                return false
            }
            return try await execute(docker, ["push", plan.image], log: log)
        }
    }

    /// 测试执行前一次性检查所有 Dockerfile，防止前面的命令先产生副作用。
    public func validate(_ images: [RunPlan.Image]) throws {
        guard Set(images.map(\.image)).count == images.count else { throw ConfigError("多个构建展开后使用了同一个镜像地址") }
        for image in images {
            if case .dockerfile(let path, _) = image.build, contained(path) == nil {
                throw ConfigError("构建 \(image.name) 的 dockerfile 不存在或指向项目外：\(path)")
            }
        }
    }

    /// 查询仓库清单并冻结摘要；认证使用 Docker 本机配置，不把凭据放进 argv。
    public func resolveDigest(_ image: String, log: JobLogStore) async throws -> String? {
        guard let docker = shell.which("docker") else {
            try await log.message("无法核验镜像：登录 shell 的 PATH 里找不到 docker")
            return nil
        }
        let arguments = ["buildx", "imagetools", "inspect", image, "--format", "{{json .Manifest}}"]
        try await log.message("核验仓库镜像：\(image)")
        let result = try await capture(docker, arguments, timeout: .seconds(60), limit: 64 * 1_024)
        struct Manifest: Decodable { var digest: String }
        guard result.result.succeeded, let manifest = try? JSONDecoder().decode(Manifest.self, from: result.stdout),
              (try? #/sha256:[a-f0-9]{64}/#.wholeMatch(in: manifest.digest)) != nil else {
            try await log.message("镜像核验失败，未获得有效的仓库 digest；不会开始部署")
            try await log.append(result.stderr, stream: .stderr)
            return nil
        }
        try await log.message("已核验镜像摘要：\(manifest.digest)")
        return manifest.digest
    }

    /// 用登录 shell 执行一行命令；`${X}` 等语法由 shell 自己处理。
    public func run(_ command: String, log: JobLogStore) async throws -> Bool {
        try await log.append(Data("$ \(command)\n".utf8), stream: .system)
        return try await finish(runner.run(self.command(shell.shell, ["-c", command]), output: Self.forward(log)), log: log)
    }

    /// 直接执行程序，参数按数组传递，不经过 shell。给出 `tail` 时同时留下输出的末尾，用来找报错原因。
    func execute(_ program: String, _ arguments: [String], environment: [String: String] = [:],
                 timeout: Duration? = nil, log: JobLogStore, tail: OutputTail? = nil) async throws -> Bool {
        let name = URL(fileURLWithPath: program).lastPathComponent
        try await log.append(Data("$ \(([name] + arguments).joined(separator: " "))\n".utf8), stream: .system)
        var command = command(program, arguments, environment: environment)
        if let timeout { command.timeout = timeout }
        return try await finish(runner.run(command, output: Self.forward(log, tail: tail)), log: log)
    }

    /// 直接执行程序并收集输出，不写日志；用于读取集群状态这类内部查询。
    func capture(_ program: String, _ arguments: [String], environment: [String: String] = [:],
                 timeout: Duration, limit: Int) async throws -> CapturedCommand {
        var command = command(program, arguments, environment: environment)
        command.timeout = timeout
        let captured = try await runner.capture(command, limit: limit)
        if captured.result.stopReason == .canceled { throw CancellationError() }
        return captured
    }

    private func command(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) -> Command {
        // 不继承调用终端可能残留的上一次运行变量。
        let clean = shell.variables.filter { !["CICD_TIME", "CICD_SHA", "CICD_BRANCH", "CICD_IMAGE", "CICD_BUILD"].contains($0.key) }
        let merged = clean.merging(variables) { $1 }.merging(environment) { $1 }
        return Command(executable: executable, arguments: arguments, directory: root.path,
                       environment: merged.mapValues { Optional($0) }, inheritEnvironment: false, timeout: commandTimeout)
    }

    private static func forward(_ log: JobLogStore, tail: OutputTail? = nil) -> @Sendable (CommandStream, Data) async throws -> Void {
        { stream, data in
            await tail?.append(data)
            try await log.append(data, stream: stream == .stdout ? .stdout : .stderr)
        }
    }

    private func finish(_ result: CommandResult, log: JobLogStore) async throws -> Bool {
        switch result.stopReason {
        case .canceled: throw CancellationError()
        case .timeout: try await log.message("命令超时，已终止")
        case nil:
            if let code = result.exitCode, code != 0 { try await log.message("命令失败，退出码 \(code)") }
            if let signal = result.signal { try await log.message("命令被信号 \(signal) 终止") }
        }
        return result.succeeded
    }

    private var resolvedRoot: URL { root.standardizedFileURL.resolvingSymlinksInPath() }

    /// 解析符号链接后仍在项目目录内的普通文件。
    private func contained(_ path: String) -> URL? {
        let base = resolvedRoot
        let url = base.appending(path: path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path + "/"),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }
}
