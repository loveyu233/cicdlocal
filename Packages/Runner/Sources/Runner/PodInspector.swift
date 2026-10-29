import Foundation
import LogKit

/// 一个起不来的新版本 Pod。
struct PodFailure: Sendable, Equatable {
    var pod: String
    var uid: String? = nil
    var container: String
    var reason: String
    var detail: String?
    var restarts: Int
    var lastExit: String?
    /// 容器已经运行过，可尝试当前日志；有重启次数时另取上一次实例日志。
    var crashed: Bool
    var currentExit: String? = nil

    /// 界面上的一行：哪个 Pod 的哪个容器、什么原因、上次怎么退出的。
    var headline: String {
        "Pod \(pod) 容器 \(container) \(reason)" + (restarts > 0 ? "，已重启 \(restarts) 次" : "")
            + (currentExit.map { "（本次退出：\($0)）" } ?? lastExit.map { "（上次退出：\($0)）" } ?? "")
    }

    var summary: String {
        var lines = ["Pod \(pod) 运行失败：容器 \(container) \(reason)" + (restarts > 0 ? "，已重启 \(restarts) 次" : "")]
        if let currentExit { lines.append("  本次退出：\(currentExit)") }
        else if let lastExit { lines.append("  上次退出：\(lastExit)") }
        if let detail, !detail.isEmpty { lines.append("  \(detail)") }
        return lines.joined(separator: "\n")
    }
}

/// Pod 的一条告警事件。
struct PodWarning: Sendable, Equatable {
    var reason: String
    var message: String
    var count: Int

    var text: String { "\(reason)：\(message)" + (count > 1 ? "（\(count) 次）" : "") }

    /// 摘要保留首尾，长镜像地址后面的认证根因通常在末尾；完整事件仍写进日志。
    var brief: String {
        text.count <= 600 ? text : String(text.prefix(180)) + "……" + String(text.suffix(400))
    }

    /// 只重复状态的说明不算原因，例如「Error: ImagePullBackOff」「Back-off restarting failed container」。
    static func informative(_ message: String?) -> String? {
        guard let message, !message.isEmpty, message.wholeMatch(of: /Error: \w+/) == nil,
              !message.lowercased().hasPrefix("back-off") else { return nil }
        return message
    }
}

/// 读取 deployment 下运行新镜像的 Pod，找出起不来的那些。只读，不改集群。
struct PodInspector: Sendable {
    let stage: StageRunner
    let kubectl: String
    let environment: [String: String]
    let target: LocalConfig.Target
    let image: String
    /// set image 后绑定的目标，任何读取失败都不能退回 namespace 按镜像猜测。
    var anchor: DeploymentInfo?

    /// 明确的启动故障；镜像拉取错误由监视器给予恢复窗口，其余故障及时结束运行。
    static let fatalReasons: Set<String> = [
        "CrashLoopBackOff", "ImagePullBackOff", "ErrImageNeverPull", "InvalidImageName",
        "CreateContainerConfigError", "CreateContainerError", "RunContainerError",
    ]

    func deployment() async throws -> DeploymentInfo {
        try await decode(DeploymentInfo.self, ["get", "deployment", target.deployment, "-n", target.namespace, "-o", "json"],
                         limit: 4 * 1_024 * 1_024)
    }

    func snapshot() async throws -> DeploymentSnapshot {
        let info = try await deployment()
        guard let anchor, let uid = anchor.metadata.uid, let generation = info.metadata.generation,
              info.metadata.uid == uid, info.metadata.deletionTimestamp == nil,
              generation >= (anchor.metadata.generation ?? 0), info.spec.template == anchor.spec.template,
              info.spec.template.spec.containers.contains(where: { $0.name == target.container && $0.image == image }) else {
            throw DeploymentChanged()
        }
        let selection = info.labelSelector.isEmpty ? [] : ["-l", info.labelSelector]
        let replicas = try await decode(ReplicaSetList.self, ["get", "replicasets", "-n", target.namespace, "-o", "json"] + selection,
                                        limit: 16 * 1_024 * 1_024).items.filter {
            $0.metadata.owned(by: uid, kind: "Deployment") && $0.spec.template == anchor.spec.template
                && $0.metadata.deletionTimestamp == nil
        }
        let ids = Set(replicas.compactMap(\.metadata.uid))
        let current = try await decode(PodList.self, ["get", "pods", "-n", target.namespace, "-o", "json"] + selection,
                                      limit: 16 * 1_024 * 1_024).items.filter { pod in
            runsNewImage(pod) && ids.contains { pod.metadata.owned(by: $0, kind: "ReplicaSet") }
        }.sorted { $0.metadata.name < $1.metadata.name }
        guard current.allSatisfy({ $0.metadata.uid != nil }) else { throw RunnerError("Pod 缺少 UID，无法验证所属关系") }
        return DeploymentSnapshot(deployment: info, replicas: replicas, pods: current)
    }

    /// Pod 最近的告警事件，例如探针失败、拉取镜像失败、调度失败；按时间排列，内容相同的只留最后一条，最多 5 条。
    func warnings(_ pod: String, uid: String? = nil, kind: String = "Pod") async throws -> [PodWarning] {
        let arguments = ["get", "events", "-n", target.namespace, "--field-selector", "involvedObject.kind=\(kind),involvedObject.name=\(pod)" + (uid.map { ",involvedObject.uid=\($0)" } ?? ""),
                         "-o", "json"]
        let events = try await decode(EventList.self, arguments, limit: 4 * 1_024 * 1_024).items
            .filter { $0.type == "Warning" }
            .sorted { ($0.lastTimestamp ?? $0.eventTime ?? "") < ($1.lastTimestamp ?? $1.eventTime ?? "") }
        var latest: [String: (index: Int, warning: PodWarning)] = [:]
        for (index, event) in events.enumerated() {
            let warning = PodWarning(reason: event.reason ?? "Warning",
                                     message: String((event.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(8192)),
                                     count: event.series?.count ?? event.count ?? 1)
            latest[warning.reason + "\n" + warning.message] = (index, warning)
        }
        return latest.values.sorted { $0.index < $1.index }.suffix(5).map(\.warning)
    }

    /// 当前与上次实例分别读取；任一份读取失败仍保留另一份和原始故障。
    func logs(_ failure: PodFailure, log: JobLogStore) async throws -> String? {
        let base = ["logs", failure.pod, "-n", target.namespace, "-c", failure.container, "--tail=200", "--limit-bytes=65536"]
        var cause: String?
        for previous in (failure.restarts > 0 ? [true, false] : [false]) {
            let label = previous ? "上一次运行的日志" : "当前日志"
            try await log.message("Pod \(failure.pod) 容器 \(failure.container) \(label)：")
            do {
                let tail = OutputTail()
                if try await stage.execute(kubectl, base + (previous ? ["--previous"] : []), environment: environment,
                                           timeout: .seconds(10), log: log, tail: tail) {
                    let line = await tail.keyLine()
                    if cause == nil { cause = line }
                    if line == nil { try await log.message("\(label)为空") }
                } else { try await log.message("读取\(label)失败；保留原始 Pod 故障") }
            } catch is CancellationError { throw CancellationError() }
            catch { try await log.message("读取\(label)失败：\(error)；保留原始 Pod 故障") }
        }
        return cause
    }

    /// 一行说明 Pod 当前的状态，例如「Pod a：Running，容器 app 就绪，重启 0 次」。
    static func describe(_ pod: Pod, container name: String) -> String {
        var phase = pod.metadata.name + "：" + (pod.status?.phase ?? "Unknown")
        // 调度不上时只有条件里有原因，例如资源不足。
        if let condition = pod.status?.conditions?.first(where: { $0.status == "False" && $0.reason != nil }), pod.status?.phase == "Pending" {
            phase += "（\(condition.reason ?? "")" + (condition.message.map { "：\($0.prefix(200))" } ?? "") + "）"
        }
        guard let container = pod.status?.containerStatuses?.first(where: { $0.name == name }) else { return "Pod \(phase)" }
        let state = if let waiting = container.state?.waiting {
            "等待中" + (waiting.reason.map { "（\($0)）" } ?? "")
        } else if let terminated = container.state?.terminated {
            "已退出（\(exitDescription(terminated))）"
        } else {
            container.ready == true && pod.status?.conditions?.contains { $0.type == "Ready" && $0.status == "True" } == true ? "就绪" : "运行中，未就绪"
        }
        return "Pod \(phase)，容器 \(name) \(state)，重启 \(container.restartCount ?? 0) 次"
    }

    // MARK: 内部

    private func decode<T: Decodable>(_ type: T.Type, _ arguments: [String], limit: Int) async throws -> T {
        let name = "kubectl \(arguments.prefix(2).joined(separator: " "))"
        let captured = try await stage.capture(kubectl, arguments, environment: environment, timeout: .seconds(10), limit: limit)
        guard captured.result.succeeded else {
            let message = captured.errorString.split(separator: "\n").first.map { String($0.prefix(300)) } ?? ""
            throw RunnerError("\(name) 失败" + (message.isEmpty ? "" : "：\(message)"))
        }
        guard let value = try? JSONDecoder().decode(type, from: captured.stdout) else { throw RunnerError("\(name) 的输出无法解析") }
        return value
    }

    private func runsNewImage(_ pod: Pod) -> Bool {
        pod.metadata.deletionTimestamp == nil
            && pod.spec.containers.contains { $0.name == target.container && $0.image == image }
    }

    /// 每个容器当前的重启次数，键为「Pod/容器」。
    static func restarts(of pods: [Pod]) -> [String: Int] {
        var result: [String: Int] = [:]
        for pod in pods {
            for container in (pod.status?.initContainerStatuses ?? []) + (pod.status?.containerStatuses ?? []) {
                result["\(pod.metadata.uid ?? pod.metadata.name)/\(container.name)"] = container.restartCount ?? 0
            }
        }
        return result
    }

    private static func exitDescription(_ terminated: Pod.Terminated) -> String {
        [terminated.reason, terminated.exitCode.map { "退出码 \($0)" }, terminated.message].compactMap { $0 }.joined(separator: "，")
    }

    /// 目标容器还没有就绪的 Pod：rollout 超时或观察结束时用来说明卡在哪里。
    static func unready(_ pods: [Pod], container name: String) -> [PodFailure] {
        pods.compactMap { pod in
            let container = pod.status?.containerStatuses?.first { $0.name == name }
            guard !(pod.status?.phase == "Running" && container?.ready == true && container?.state?.running != nil
                    && pod.status?.conditions?.contains { $0.type == "Ready" && $0.status == "True" } == true) else { return nil }
            let reason = container?.state?.waiting?.reason.map { "等待中（\($0)）" } ?? (container == nil ? "未启动（\(pod.status?.phase ?? "Unknown")）" : "未就绪")
            let restarts = container?.restartCount ?? 0
            return PodFailure(pod: pod.metadata.name, uid: pod.metadata.uid, container: name, reason: reason,
                              // 调度不上时只有 PodScheduled 条件里有原因；「containers with unready status」这类说明没有信息量。
                              detail: container?.state?.waiting?.message
                                  ?? pod.status?.conditions?.first { $0.type == "PodScheduled" && $0.status == "False" }?.message,
                              restarts: restarts, lastExit: container?.lastState?.terminated.map(exitDescription),
                              crashed: container?.state?.running != nil || container?.state?.terminated != nil || restarts > 0)
        }
    }

    /// 给出 `baseline`（rollout 完成时的重启次数）时，之后再重启一次就算失败，以前的重启不算。
    static func failures(of pod: Pod, baseline: [String: Int]? = nil) -> [PodFailure] {
        guard let status = pod.status else { return [] }
        let containers = (status.initContainerStatuses ?? []) + (status.containerStatuses ?? [])
        let failures: [PodFailure] = containers.compactMap { container in
            let restarts = container.restartCount ?? 0
            let last = container.lastState?.terminated
            let lastExit = last.map(exitDescription)
            if let terminated = container.state?.terminated,
               terminated.reason == "OOMKilled" || (terminated.exitCode ?? 0) != 0 {
                return PodFailure(pod: pod.metadata.name, uid: pod.metadata.uid, container: container.name,
                                  reason: terminated.reason ?? "异常退出",
                                  detail: terminated.reason == "OOMKilled" ? "容器因内存不足被终止" : terminated.message,
                                  restarts: restarts, lastExit: lastExit, crashed: true, currentExit: exitDescription(terminated))
            }
            if let waiting = container.state?.waiting, let reason = waiting.reason,
               fatalReasons.contains(reason) || reason == "ErrImagePull" {
                let crashed = reason == "CrashLoopBackOff" || reason == "RunContainerError" || restarts > 0
                return PodFailure(pod: pod.metadata.name, uid: pod.metadata.uid, container: container.name, reason: reason, detail: waiting.message,
                                  restarts: restarts, lastExit: lastExit, crashed: crashed)
            }
            if container.ready != true, last?.reason == "OOMKilled" {
                return PodFailure(pod: pod.metadata.name, uid: pod.metadata.uid, container: container.name,
                                  reason: "OOMKilled", detail: "上一次容器因内存不足被终止，当前尚未恢复就绪",
                                  restarts: restarts, lastExit: lastExit, crashed: true)
            }
            // 服务就绪后才崩溃：rollout status 已经报告成功，但容器又重启了。
            if let baseline, let previous = baseline["\(pod.metadata.uid ?? pod.metadata.name)/\(container.name)"], restarts > previous {
                return PodFailure(pod: pod.metadata.name, uid: pod.metadata.uid, container: container.name, reason: "rollout 完成后崩溃重启", detail: nil,
                                  restarts: restarts, lastExit: lastExit, crashed: true)
            }
            // 还没进入 CrashLoopBackOff，但已经反复非零退出。正在运行且就绪的不算：重新替换同一镜像时，以前的重启不是这次的问题。
            if baseline?["\(pod.metadata.uid ?? pod.metadata.name)/\(container.name)"] == nil, container.ready != true, restarts >= 2, let code = last?.exitCode, code != 0 {
                return PodFailure(pod: pod.metadata.name, uid: pod.metadata.uid, container: container.name, reason: "反复退出", detail: nil,
                                  restarts: restarts, lastExit: lastExit, crashed: true)
            }
            return nil
        }
        if !failures.isEmpty { return failures }
        if status.phase == "Failed" {
            return [PodFailure(pod: pod.metadata.name, uid: pod.metadata.uid, container: pod.spec.containers.first?.name ?? "",
                               reason: status.reason ?? "Failed", detail: status.message, restarts: 0, lastExit: nil, crashed: false)]
        }
        return []
    }
}

// MARK: - kubectl JSON（只解码用到的字段）

struct EventList: Decodable, Sendable {
    struct Event: Decodable, Sendable {
        struct Series: Decodable, Sendable { var count: Int? }
        var type: String?
        var reason: String?
        var message: String?
        var count: Int?
        var series: Series?
        var lastTimestamp: String?
        var eventTime: String?
    }
    var items: [Event]
}

struct PodList: Decodable, Sendable { var items: [Pod] }

struct Pod: Decodable, Sendable {
    struct Spec: Decodable, Sendable { var containers: [Container] }
    struct Container: Decodable, Sendable {
        var name: String
        var image: String?
    }
    struct Status: Decodable, Sendable {
        var phase: String?
        var reason: String?
        var message: String?
        var conditions: [Condition]?
        var containerStatuses: [ContainerStatus]?
        var initContainerStatuses: [ContainerStatus]?
    }
    struct Condition: Decodable, Sendable {
        var type: String?
        var status: String?
        var reason: String?
        var message: String?
    }
    struct ContainerStatus: Decodable, Sendable {
        var name: String
        var ready: Bool?
        var restartCount: Int?
        var state: State?
        var lastState: State?
    }
    struct State: Decodable, Sendable {
        struct Running: Decodable, Sendable {}
        var waiting: Waiting?
        var running: Running?
        var terminated: Terminated?
    }
    struct Waiting: Decodable, Sendable {
        var reason: String?
        var message: String?
    }
    struct Terminated: Decodable, Sendable {
        var reason: String?
        var message: String?
        var exitCode: Int?
    }

    var metadata: ResourceMetadata
    var spec: Spec
    var status: Status?
}
