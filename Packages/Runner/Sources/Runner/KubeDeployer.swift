import Darwin
import Foundation
import LogKit

/// 替换阶段：用钥匙串里该环境的 kubeconfig 执行 kubectl set image，再确认新版本真的跑起来了。
/// kubeconfig 只写进 0600 临时文件并通过 KUBECONFIG 传给 kubectl，不出现在参数和日志里，用完即删。
///
/// 「替换成功」要同时满足：
/// 1. rollout status 报告完成，即新 Pod 都通过了就绪判断，旧 Pod 已经替换掉；
/// 2. rollout 完成后再观察 `settleDuration`，新 Pod 没有重启，观察结束时仍然就绪。
///    没有就绪探针的服务，进程一启动就算就绪，读配置失败这类错误要到之后才崩溃，只有这一步能发现。
///
/// set image 后每隔 `pollInterval` 查一次新镜像的 Pod，状态变化写进阶段日志。反复崩溃、拉不到镜像、建不了容器时
/// 明确崩溃及时停止等待；镜像拉取错误先展示事件并给予恢复窗口。失败时写出告警事件、当前和上次实例日志，
/// 并把原因和日志里的报错作为阶段结果显示在界面上。
public struct KubeDeployer: Sendable {
    public let stage: StageRunner
    /// 应用自己的临时目录，权限 0700。
    public let temporaryDirectory: URL
    public var rolloutTimeout = "10m"
    public var pollInterval: Duration = .seconds(2)
    /// rollout 完成后连续就绪的观察时长；为零仍须校验一次完整状态。
    public var settleDuration: Duration = .seconds(60)
    public var settleTimeout: Duration = .seconds(180)
    public var imagePullGrace: Duration = .seconds(30)
    var diagnosticTimeout: Duration = .seconds(90)

    public init(stage: StageRunner, temporaryDirectory: URL) {
        self.stage = stage
        self.temporaryDirectory = temporaryDirectory
    }

    public func deploy(_ target: LocalConfig.Target, image: String, kubeconfig: Data, log: JobLogStore) async throws -> StageResult {
        let result = try await performDeployment(target, image: image, kubeconfig: kubeconfig, log: log)
        try await log.message("部署结果：" + (result.succeeded ? "成功" : "失败") + (result.message.map { "；\($0)" } ?? ""))
        return result
    }

    private func performDeployment(_ target: LocalConfig.Target, image: String, kubeconfig: Data, log: JobLogStore) async throws -> StageResult {
        guard let kubectl = stage.shell.which("kubectl") else {
            try await log.message("在登录 shell 的 PATH 里找不到 kubectl，请确认在终端里能直接运行 kubectl")
            return .failed("找不到 kubectl")
        }
        try await log.message("替换环境「\(target.k8s)」：\(target.namespace)/\(target.deployment) 的容器 \(target.container) → \(image)")
        let file = try writeKubeconfig(kubeconfig)
        defer { unlink(file.path) }
        let environment = ["KUBECONFIG": file.path]
        let deployment = "deployment/\(target.deployment)"
        let setTail = OutputTail()
        guard try await stage.execute(kubectl, ["set", "image", deployment, "\(target.container)=\(image)", "-n", target.namespace],
                                      environment: environment, timeout: .seconds(120), log: log, tail: setTail) else {
            return .failed("kubectl set image 失败" + (await setTail.keyLine().map { "：\($0)" } ?? ""))
        }

        var pods = PodInspector(stage: stage, kubectl: kubectl, environment: environment, target: target, image: image)
        // 无法绑定目标时明确失败，绝不按 namespace 中的相同镜像猜测。
        for attempt in 1...3 {
            do {
                let info = try await pods.deployment()
                guard info.metadata.uid != nil, info.metadata.generation != nil else { throw RunnerError("Deployment 缺少 UID 或 generation") }
                guard info.spec.template.spec.containers.contains(where: { $0.name == target.container && $0.image == image }) else {
                    return .failed("本次部署已被后续变更覆盖：Deployment 的目标镜像与本次不一致")
                }
                pods.anchor = info
                break
            } catch is CancellationError { throw CancellationError() }
            catch {
                try await log.message("读取 Deployment 失败（第 \(attempt)/3 次）：\(error)")
                if attempt == 3 { return .failed("镜像已替换，但健康检查未完成：\(error)") }
                try await Task.sleep(for: pollInterval)
            }
        }
        let readinessProbe = pods.anchor?.hasReadinessProbe(target.container) == true
        if !readinessProbe {
            try await log.message("容器 \(target.container) 没有配置就绪探针（readinessProbe）：只能确认进程没有退出，业务可用性未验证。")
        }
        let rollout = ["rollout", "status", deployment, "-n", target.namespace, "--timeout=\(rolloutTimeout)"]
        let tail = OutputTail()
        let status = StatusLog()
        let outcome = try await withThrowingTaskGroup(of: RolloutOutcome.self) { [pods] group in
            group.addTask {
                .finished(try await stage.execute(kubectl, rollout, environment: environment,
                                                  timeout: .seconds(15 * 60), log: log, tail: tail))
            }
            group.addTask { try await watch(pods, status: status, log: log) }
            let next = try await group.next() ?? .finished(false)
            // 返回时取消另外一个任务，同时终止其 kubectl 进程组。
            group.cancelAll()
            return next
        }
        switch outcome {
        case .finished(true): return try await settle(pods, readinessProbe: readinessProbe, status: status, log: log)
        case .finished(false):
            do {
                let current = try await check(pods, status: status, log: log)
                let failures = current.pods.flatMap { PodInspector.failures(of: $0) }
                let unready = PodInspector.unready(current.pods, container: target.container)
                if !failures.isEmpty || !unready.isEmpty {
                    return .failed("rollout 没有完成：" + (try await report(failures.isEmpty ? unready : failures, pods: pods, log: log)))
                }
                try await workloadWarnings(current, pods: pods, log: log)
                return .failed("rollout 没有完成：" + current.summary + (await tail.keyLine().map { "；\($0)" } ?? ""))
            } catch is CancellationError { throw CancellationError() }
            catch {
                try await log.message("rollout 失败后的状态检查未完成：\(error)")
                return .failed("rollout 没有完成" + (await tail.keyLine().map { "：\($0)" } ?? "") + "；健康检查未完成：\(error)")
            }
        case .podsFailed(let failures):
            try await log.message("新镜像的 Pod 无法正常运行，停止等待 rollout")
            return .failed(try await report(failures, pods: pods, log: log))
        case .inspectionFailed(let message): return .failed(message)
        }
    }

    private enum RolloutOutcome: Sendable {
        case finished(Bool), podsFailed([PodFailure]), inspectionFailed(String)
    }

    private func watch(_ pods: PodInspector, status: StatusLog, log: JobLogStore) async throws -> RolloutOutcome {
        var errors = 0
        while true {
            try await Task.sleep(for: pollInterval)
            do {
                let current = try await check(pods, status: status, log: log)
                if current.expected == 0 { return .inspectionFailed("期望副本为 0，没有运行实例，无法验证服务启动") }
                let failures = await status.confirmed(current.pods.flatMap { PodInspector.failures(of: $0) }, grace: imagePullGrace)
                if !failures.isEmpty { return .podsFailed(failures) }
                errors = 0
            } catch is CancellationError { throw CancellationError() }
            catch let error as DeploymentChanged { return .inspectionFailed(error.description) }
            catch {
                errors += 1
                try await log.message("健康检查读取失败（第 \(errors)/3 次）：\(error)")
                if errors >= 3 { return .inspectionFailed("镜像已替换，但健康检查未完成：\(error)") }
            }
        }
    }

    private func check(_ inspector: PodInspector, status: StatusLog, log: JobLogStore) async throws -> DeploymentSnapshot {
        let current = try await inspector.snapshot()
        let text = current.summary + "\n" + (current.pods.isEmpty ? "还没有运行新镜像的目标 Pod"
            : current.pods.map { PodInspector.describe($0, container: inspector.target.container) }.joined(separator: "\n"))
        if await status.changed(text) { try await log.message(text) }
        let failures = current.pods.flatMap { PodInspector.failures(of: $0) }
        let unready = PodInspector.unready(current.pods, container: inspector.target.container)
        let issues = failures + unready
        // 错误一出现就展示事件，包含 ErrImagePull 阶段的认证、网络或镜像不存在等原始原因。
        var visited = Set<String>()
        for issue in issues where visited.count < 3 {
            let key = issue.uid ?? issue.pod
            guard visited.insert(key).inserted else { continue }
            if await status.once("异常/" + issue.summary) { try await log.message("发现异常：" + issue.headline + (issue.detail.map { "；\($0)" } ?? "")) }
            do {
                for warning in try await inspector.warnings(issue.pod, uid: issue.uid) {
                    if await status.once(key + warning.text) { try await log.message("Pod \(issue.pod) 告警：\(warning.text)") }
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                if await status.once(key + "事件/" + String(describing: error)) {
                    try await log.message("Pod \(issue.pod) 告警读取失败：\(error)；保留原始状态")
                }
            }
        }
        let recovered = await status.recovered(issues: Set(issues.map { $0.uid ?? $0.pod }),
                                               healthy: current.pods.filter { PodInspector.unready([$0], container: inspector.target.container).isEmpty })
        for name in recovered { try await log.message("Pod \(name) 已恢复就绪") }
        return current
    }

    /// rollout 和观察阶段共用去重与拉取恢复窗口；只有明确就绪才记录恢复。
    private actor StatusLog {
        private var last: String?
        private var messages = Set<String>()
        private var unhealthy = Set<String>()
        private var pulling: [String: ContinuousClock.Instant] = [:]
        func changed(_ text: String) -> Bool { defer { last = text }; return text != last }
        func once(_ text: String) -> Bool {
            if messages.count > 2_000 { messages.removeAll(keepingCapacity: true) }
            return messages.insert(text).inserted
        }
        func recovered(issues: Set<String>, healthy: [Pod]) -> [String] {
            unhealthy.formUnion(issues)
            return healthy.filter { !issues.contains($0.metadata.uid ?? $0.metadata.name) && unhealthy.remove($0.metadata.uid ?? $0.metadata.name) != nil }.map(\.metadata.name)
        }
        func confirmed(_ failures: [PodFailure], grace: Duration) -> [PodFailure] {
            let keys = Set(failures.filter { ["ErrImagePull", "ImagePullBackOff"].contains($0.reason) }
                .map { ($0.uid ?? $0.pod) + "/" + $0.container })
            pulling = pulling.filter { keys.contains($0.key) }
            return failures.filter { failure in
                guard ["ErrImagePull", "ImagePullBackOff"].contains(failure.reason) else { return true }
                let key = (failure.uid ?? failure.pod) + "/" + failure.container
                let first = pulling[key] ?? .now
                pulling[key] = first
                return ContinuousClock.now - first >= grace
            }
        }
    }

    private func settle(_ pods: PodInspector, readinessProbe: Bool, status: StatusLog, log: JobLogStore) async throws -> StageResult {
        try await log.message("rollout 已完成，继续观察 \(settleDuration.components.seconds) 秒，确认全部目标副本连续就绪且没有崩溃重启")
        let deadline = ContinuousClock.now + max(settleTimeout, settleDuration)
        var stableSince: ContinuousClock.Instant?
        var identities = Set<String>()
        var baseline: [String: Int] = [:]
        var errors = 0
        var latest: DeploymentSnapshot?
        var lastError: String?
        repeat {
            do {
                let current = try await check(pods, status: status, log: log)
                latest = current
                errors = 0
                lastError = nil
                if current.expected == 0 { return .failed("期望副本为 0，没有运行实例，无法验证服务启动") }
                let failures = await status.confirmed(current.pods.flatMap { PodInspector.failures(of: $0, baseline: baseline) }, grace: imagePullGrace)
                if !failures.isEmpty {
                    try await log.message("新镜像的 Pod 在 rollout 完成后崩溃或启动失败")
                    return .failed(try await report(failures, pods: pods, log: log))
                }
                // 新 UID 建立自己的基线，旧 UID 的历史仍保留，不能因 Pod 消失而漏过新增重启。
                baseline.merge(PodInspector.restarts(of: current.pods)) { old, _ in old }
                let currentIDs = Set(current.pods.compactMap(\.metadata.uid))
                if identities != currentIDs { stableSince = nil; identities = currentIDs }
                if current.complete(container: pods.target.container) {
                    if stableSince == nil { stableSince = .now }
                    if let since = stableSince, ContinuousClock.now - since >= settleDuration {
                        let message = "替换完成：\(current.pods.count) 个目标 Pod 已就绪，\(settleDuration.components.seconds) 秒内没有重启"
                            + (readinessProbe ? "" : "。容器没有就绪探针，只能确认进程没有退出，业务可用性未验证")
                        return StageResult(succeeded: true, message: message)
                    }
                } else { stableSince = nil }
            } catch is CancellationError { throw CancellationError() }
            catch let error as DeploymentChanged { return .failed(error.description) }
            catch {
                errors += 1
                stableSince = nil
                lastError = String(describing: error)
                try await log.message("健康检查读取失败（第 \(errors)/3 次）：\(error)")
                if errors >= 3 { return .failed("镜像已替换，但健康检查未完成：\(error)") }
            }
            if ContinuousClock.now < deadline { try await Task.sleep(for: min(pollInterval, deadline - .now)) }
        } while ContinuousClock.now < deadline
        if let lastError { return .failed("镜像已替换，但健康检查未完成：\(lastError)") }
        if let latest {
            let unready = PodInspector.unready(latest.pods, container: pods.target.container)
            if !unready.isEmpty { return .failed("观察超时：" + (try await report(unready, pods: pods, log: log))) }
            try await workloadWarnings(latest, pods: pods, log: log)
            return .failed("观察超时，未能确认全部副本持续就绪：" + latest.summary)
        }
        return .failed("健康检查未完成：没有获取到目标 Pod 状态")
    }

    private func workloadWarnings(_ snapshot: DeploymentSnapshot, pods: PodInspector, log: JobLogStore) async throws {
        for resource in [("Deployment", snapshot.deployment.metadata)] + snapshot.replicas.prefix(3).map({ ("ReplicaSet", $0.metadata) }) {
            do {
                for warning in try await pods.warnings(resource.1.name, uid: resource.1.uid, kind: resource.0) {
                    try await log.message("\(resource.0) \(resource.1.name) 告警：\(warning.text)")
                }
            } catch is CancellationError { throw CancellationError() }
            catch { try await log.message("\(resource.0) 告警读取失败：\(error)") }
        }
    }

    /// 取证有总时限，诊断读取失败和超时不会替换原始故障；取消仍向上传递。
    private func report(_ failures: [PodFailure], pods: PodInspector, log: JobLogStore) async throws -> String {
        let summary = failures.prefix(3).map(\.headline).joined(separator: "\n")
        for failure in failures { try await log.message(failure.summary) }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await collect(failures, pods: pods, log: log) }
            group.addTask {
                try await Task.sleep(for: diagnosticTimeout)
                try await log.message("故障取证达到时间上限，保留已收集日志和原始故障")
                return summary + "\n部分诊断未完成：取证超时"
            }
            let result = try await group.next() ?? summary
            group.cancelAll()
            return result
        }
    }

    private func collect(_ failures: [PodFailure], pods: PodInspector, log: JobLogStore) async throws -> String {
        var selected: [String] = []
        for failure in failures where !selected.contains(failure.uid ?? failure.pod) {
            selected.append(failure.uid ?? failure.pod)
        }
        if selected.count > 3 { try await log.message("共 \(selected.count) 个异常 Pod，详细取证限前 3 个") }
        var summaries: [String] = []
        for key in selected.prefix(3) {
            let items = failures.filter { ($0.uid ?? $0.pod) == key }
            guard let first = items.first else { continue }
            var warnings: [PodWarning] = []
            do {
                warnings = try await pods.warnings(first.pod, uid: first.uid)
                try await log.message((["Pod \(first.pod) 的告警事件："] + warnings.map { "  \($0.text)" }).joined(separator: "\n"))
            } catch is CancellationError { throw CancellationError() }
            catch { try await log.message("Pod \(first.pod) 告警读取失败：\(error)；保留原始故障") }
            for failure in items.prefix(3) {
                var line: String?
                if failure.crashed { line = try await pods.logs(failure, log: log) }
                else { try await log.message("Pod \(failure.pod) 容器 \(failure.container) 尚未启动，暂无容器日志") }
                let detail = PodWarning.informative(failure.detail.map { String($0.prefix(300)) })
                let warning = warnings.last { PodWarning.informative($0.message) != nil }.map(\.brief)
                let cause = (failure.restarts > 0 ? [line, warning, detail] : [warning, detail, line]).compactMap { $0 }.first
                summaries.append(failure.headline + (cause.map { "\n\($0)" } ?? ""))
            }
        }
        try await log.message("deployment 已经指向新镜像。本次未自动回滚；修复后重新推送，或使用之前运行的「重新替换」恢复。")
        return summaries.joined(separator: "\n")
    }

    private func writeKubeconfig(_ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = temporaryDirectory.appending(path: "kubeconfig-\(UUID().uuidString)")
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RunnerError("无法创建临时 kubeconfig 文件") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            unlink(url.path)
            throw RunnerError("无法写入临时 kubeconfig 文件")
        }
        return url
    }
}

public struct RunnerError: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
