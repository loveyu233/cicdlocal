import Foundation
import Subprocess
import System

public struct CommandError: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum ProcessStopReason: Sendable, Equatable { case canceled, timeout }
public enum CommandStream: Sendable, Equatable { case stdout, stderr }

public struct Command: Sendable {
    public var executable: String
    public var arguments: [String]
    public var directory: String?
    /// nil 继承宿主环境；字典值为 nil 删除该变量。调用者不要把凭据放在 arguments 中。
    public var environment: [String: String?]
    public var inheritEnvironment: Bool
    public var input: Data
    public var timeout: Duration?
    public var terminationGrace: Duration

    public init(
        executable: String, arguments: [String] = [], directory: String? = nil,
        environment: [String: String?] = [:], inheritEnvironment: Bool = true,
        input: Data = Data(), timeout: Duration? = .seconds(60), terminationGrace: Duration = .seconds(2)
    ) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
        self.inheritEnvironment = inheritEnvironment
        self.input = input
        self.timeout = timeout
        self.terminationGrace = terminationGrace
    }
}

public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32?
    public var signal: Int32?
    public var stopReason: ProcessStopReason?
    public var succeeded: Bool { exitCode == 0 && stopReason == nil }
}

public struct CapturedCommand: Sendable {
    public var result: CommandResult
    public var stdout: Data
    public var stderr: Data
    public var outputString: String { String(decoding: stdout, as: UTF8.self) }
    public var errorString: String { String(decoding: stderr, as: UTF8.self) }
}

/// 所有外部进程使用参数数组；stdout/stderr 并发消费，回调提供背压，不在内存里无限排队。
public struct CommandRunner: Sendable {
    public init() {}

    public func capture(_ command: Command, limit: Int = 4 * 1_024 * 1_024) async throws -> CapturedCommand {
        let collector = CommandCollector(limit: max(0, limit))
        let result = try await run(command, output: { stream, data in try await collector.append(stream, data) })
        return await CapturedCommand(result: result, stdout: collector.stdout, stderr: collector.stderr)
    }

    public func run(
        _ command: Command,
        onStarted: @escaping @Sendable (Int32) async throws -> Void = { _ in },
        output: @escaping @Sendable (CommandStream, Data) async throws -> Void = { _, _ in }
    ) async throws -> CommandResult {
        guard command.executable.hasPrefix("/"), !command.executable.utf8.contains(0),
            command.arguments.allSatisfy({ !$0.utf8.contains(0) }),
            command.environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && $0.value?.utf8.contains(0) != true })
        else { throw CommandError("命令路径、参数或环境变量含无效内容") }
        let group = ProcessGroup(grace: command.terminationGrace)
        // 独立任务负责等待进程与两路输出结束，外层取消只请求清理，不能提前丢弃进程句柄。
        let execution = Task.detached {
            var options = PlatformOptions()
            options.processGroupID = 0
            options.teardownSequence = [.send(signal: .terminate, toProcessGroup: true, allowedDurationToNextStep: command.terminationGrace)]
            let overrides = Dictionary(uniqueKeysWithValues: command.environment.map { (Environment.Key(stringLiteral: $0.key), $0.value) })
            let environment: Environment = (command.inheritEnvironment ? Environment.inherit : Environment.custom([:])).updating(overrides)
            do {
                let result = try await Subprocess.run(
                    .path(FilePath(command.executable)), arguments: Arguments(command.arguments),
                    environment: environment, workingDirectory: command.directory.map { FilePath($0) },
                    platformOptions: options, input: .data(command.input), output: .sequence, error: .sequence
                ) { process in
                    try await group.register(process.processIdentifier.value, timeout: command.timeout)
                    do {
                        do { try await onStarted(process.processIdentifier.value) }
                        catch { throw CommandCallbackError(underlying: error) }
                        async let stdout: Void = Self.consume(process.standardOutput, stream: .stdout, output: output)
                        async let stderr: Void = Self.consume(process.standardError, stream: .stderr, output: output)
                        _ = try await (stdout, stderr)
                    } catch {
                        _ = await group.stop(nil)
                        throw error
                    }
                }
                guard await group.finish() else { throw CommandError("子进程组未能完全清理，执行资源仍需核实") }
                let reason = await group.reason
                return switch result.terminationStatus {
                case .exited(let code): CommandResult(exitCode: code, signal: nil, stopReason: reason)
                case .signaled(let signal): CommandResult(exitCode: nil, signal: signal, stopReason: reason)
                }
            } catch {
                guard await group.finish() else { throw CommandError("外部命令异常且进程组清理未完成，请核实残留资源") }
                if let error = error as? CommandCallbackError { throw error.underlying }
                // 外部库错误可能含环境变量或命令，不直接放进用户日志。
                if let error = error as? CommandError { throw error }
                throw CommandError("无法执行外部命令，请检查程序路径、目录权限和输出处理")
            }
        }
        return try await withTaskCancellationHandler {
            if Task.isCancelled { _ = await group.stop(.canceled) }
            return try await execution.value
        } onCancel: {
            Task { _ = await group.stop(.canceled) }
        }
    }

    private static func consume(
        _ sequence: SubprocessOutputSequence, stream: CommandStream,
        output: @escaping @Sendable (CommandStream, Data) async throws -> Void
    ) async throws {
        for try await buffer in sequence {
            let data = buffer.withUnsafeBytes { Data($0) }
            do { try await output(stream, data) }
            catch { throw CommandCallbackError(underlying: error) }
        }
    }
}

/// 业务回调的结构化错误原样交回调用方；外部进程库的错误仍使用经过收敛的中文提示。
private struct CommandCallbackError: Error {
    let underlying: any Error
}

private actor CommandCollector {
    let limit: Int
    var stdout = Data()
    var stderr = Data()
    init(limit: Int) { self.limit = limit }
    func append(_ stream: CommandStream, _ data: Data) throws {
        guard data.count <= limit - stdout.count - stderr.count else { throw CommandError("命令输出超过允许的采集大小") }
        switch stream {
        case .stdout: stdout.append(data)
        case .stderr: stderr.append(data)
        }
    }
}
