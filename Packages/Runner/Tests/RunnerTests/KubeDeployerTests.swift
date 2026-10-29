import Foundation
import Testing
@testable import Runner

/// 全部响应都是人工构造的 Kubernetes JSON；可执行文件只读本测试的临时目录。
struct ClusterFixture {
    static let image = "r.invalid/demo:new"
    static let token = "kube-secret-token-123"
    static let target = LocalConfig.Target(branch: "dev", k8s: "测试环境", namespace: "demo", deployment: "demo", container: "app")
    let box: Sandbox

    static func container(_ reason: String? = nil, restarts: Int = 0, ready: Bool = true,
                          terminated: Bool = false, name: String = "app") -> [String: Any] {
        var value: [String: Any] = ["name": name, "ready": ready, "restartCount": restarts]
        if terminated { value["state"] = ["terminated": ["reason": reason ?? "Error", "exitCode": 137]] }
        else if let reason { value["state"] = ["waiting": ["reason": reason, "message": "容器正在等待重试"]] }
        else { value["state"] = ["running": [:]] }
        if restarts > 0 { value["lastState"] = ["terminated": ["reason": "Error", "exitCode": 1]] }
        return value
    }

    static func pod(_ status: [String: Any] = container(), name: String = "demo-new", uid: String = "pod-1",
                    owner: String = "rs-1", initStatus: [String: Any]? = nil, podReady: Bool? = nil) -> [String: Any] {
        var state: [String: Any] = ["phase": "Running", "containerStatuses": [status],
                                   "conditions": [["type": "Ready", "status": (podReady ?? (status["ready"] as? Bool == true)) ? "True" : "False"]]]
        if let initStatus { state["initContainerStatuses"] = [initStatus] }
        return ["metadata": ["name": name, "uid": uid, "ownerReferences": [["uid": owner, "kind": "ReplicaSet", "controller": true]]],
                "spec": ["containers": [["name": "app", "image": image]]], "status": state]
    }

    static func frame(pods: [[String: Any]] = [pod()], replicas: Int = 1, available: Int = 1,
                      generation: Int = 1, observed: Int = 1, probe: Bool = true,
                      templateChange: Bool = false, deploymentUID: String = "deployment-1") -> [String: Any] {
        var container: [String: Any] = ["name": "app", "image": image]
        if probe { container["readinessProbe"] = ["httpGet": ["path": "/healthz", "port": 8080]] }
        if templateChange { container["args"] = ["changed"] }
        let template: [String: Any] = ["metadata": ["labels": ["app": "demo"]], "spec": ["containers": [container]]]
        return [
            "deployment": ["metadata": ["name": "demo", "uid": deploymentUID, "generation": generation],
                           "spec": ["replicas": replicas, "selector": ["matchLabels": ["app": "demo"]], "template": template],
                           "status": ["observedGeneration": observed, "replicas": replicas, "updatedReplicas": replicas,
                                      "readyReplicas": available, "availableReplicas": available]],
            "replicasets": ["items": [["metadata": ["name": "demo-rs", "uid": "rs-1",
                                                    "ownerReferences": [["uid": deploymentUID, "kind": "Deployment", "controller": true]]],
                                       "spec": ["template": template]]]],
            "pods": ["items": pods]
        ]
    }

    init(frames: [[String: Any]] = [frame()], rollout: String = "exit 0", queryError: String? = nil,
         event: String = "Readiness probe failed: connection refused", eventError: Bool = false,
         logError: Bool = false, setError: Bool = false, podScript: String = "", logScript: String = "") throws {
        box = try Sandbox()
        for (index, frame) in frames.enumerated() {
            for kind in ["deployment", "replicasets", "pods"] {
                try JSONSerialization.data(withJSONObject: frame[kind]!).write(to: box.root.appending(path: "\(index)-\(kind).json"))
            }
        }
        let events = ["items": [["type": "Warning", "reason": "Failed", "message": event, "count": 2]]]
        try JSONSerialization.data(withJSONObject: events).write(to: box.root.appending(path: "events.json"))
        try box.tool("kubectl", """
            root='\(box.root.path)'
            echo "args: $*" >> "$root/record.txt"
            echo "mode: $(stat -f %Lp "$KUBECONFIG")" >> "$root/record.txt"
            echo "config: $KUBECONFIG" >> "$root/record.txt"
            n=0; [ -f "$root/count" ] && n=$(cat "$root/count")
            [ "$n" -gt \(frames.count - 1) ] && n=\(frames.count - 1)
            case "$1 $2" in
              'set image') \(setError ? "echo 'error: 模拟替换失败' >&2; exit 1" : "exit 0") ;;
              'rollout status') echo $$ > "$root/rollout.pid"; \(rollout) ;;
              'get deployment'|'get replicasets') cat "$root/$n-$2.json" ;;
              'get pods')
                \(podScript)
                \(queryError.map { "echo '\($0)' >&2; exit 1" } ?? "")
                cat "$root/$n-pods.json"
                echo $((n+1)) > "$root/count" ;;
              'get events') \(eventError ? "echo 'Forbidden: 无权读取事件' >&2; exit 1" : "cat \"$root/events.json\"") ;;
              logs*)
                \(logScript)
                \(logError ? "echo 'Forbidden: 无权读取日志' >&2; exit 1" : "")
                case "$*" in *--previous*) echo 'panic: 数据库连接失败' ;; *) echo 'error: 当前实例启动失败' ;; esac ;;
              *) echo '未定义的假 kubectl 命令' >&2; exit 1 ;;
            esac
            """)
    }

    func deployer() -> KubeDeployer {
        var deployer = KubeDeployer(stage: box.stage(), temporaryDirectory: box.root.appending(path: "tmp"))
        deployer.pollInterval = .milliseconds(40)
        deployer.settleDuration = .milliseconds(150)
        deployer.settleTimeout = .seconds(2)
        deployer.imagePullGrace = .milliseconds(150)
        return deployer
    }
}

@Suite("替换镜像健康检测")
struct KubeDeployerTests {
    func run(_ fixture: ClusterFixture, deployer: KubeDeployer? = nil) async throws -> (StageResult, String) {
        let log = try fixture.box.log(secrets: [ClusterFixture.token])
        let result = try await (deployer ?? fixture.deployer()).deploy(ClusterFixture.target, image: ClusterFixture.image,
                           kubeconfig: Data(ClusterFixture.token.utf8), log: log)
        return (result, try await fixture.box.text(log))
    }

    @Test("全部副本连续就绪才成功；凭据仅在 0600 临时文件中，用完删除")
    func successAndCredentials() async throws {
        let fixture = try ClusterFixture()
        defer { fixture.box.remove() }
        let (result, text) = try await run(fixture)
        #expect(result.succeeded)
        #expect(text.contains("1 个目标 Pod 已就绪"))
        #expect(!text.contains(ClusterFixture.token))
        let lines = try fixture.box.recorded().split(separator: "\n").map(String.init)
        #expect(lines.filter { $0.hasPrefix("mode:") }.allSatisfy { $0 == "mode: 600" })
        for path in lines.filter({ $0.hasPrefix("config: ") }).map({ String($0.dropFirst(8)) }) {
            #expect(!FileManager.default.fileExists(atPath: path))
        }
        #expect(!lines.filter { $0.hasPrefix("args:") }.contains { $0.contains(ClusterFixture.token) || $0.contains("kubeconfig-") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.box.root.appending(path: "tmp").path).isEmpty)
    }

    @Test("崩溃循环立即停止 rollout，读取当前和上次日志")
    func crashLoop() async throws {
        let fixture = try ClusterFixture(frames: [ClusterFixture.frame(pods: [ClusterFixture.pod(ClusterFixture.container("CrashLoopBackOff", restarts: 3, ready: false))])], rollout: "exec sleep 60")
        defer { fixture.box.remove() }
        let (result, text) = try await run(fixture)
        #expect(!result.succeeded && result.message?.contains("CrashLoopBackOff") == true)
        #expect(result.message?.contains("panic: 数据库连接失败") == true)
        #expect(text.contains("当前日志") && text.contains("上一次运行的日志"))
        #expect(text.contains("当前实例启动失败") && text.contains("退出码 1"))
        let pid = try #require(Int32(String(contentsOf: fixture.box.root.appending(path: "rollout.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0)
    }

    @Test("镜像拉取故障显示原始原因，不读取尚未启动容器的日志", arguments: [
        "unauthorized: authentication required", "denied: requested access to the resource is denied",
        "manifest unknown", "dial tcp: i/o timeout", "lookup registry: no such host", "x509: certificate signed by unknown authority",
        "FailedToRetrieveImagePullSecret: secret not found"
    ])
    func imagePull(_ error: String) async throws {
        let fixture = try ClusterFixture(frames: [ClusterFixture.frame(pods: [ClusterFixture.pod(ClusterFixture.container("ImagePullBackOff", ready: false))])],
                                         rollout: "exec sleep 60", event: error)
        defer { fixture.box.remove() }
        let (result, text) = try await run(fixture)
        #expect(!result.succeeded)
        #expect(text.contains(error) && result.message?.contains(error) == true)
        #expect(text.contains("尚未启动，暂无容器日志"))
        #expect(try !fixture.box.recorded().contains("args: logs"))
        #expect(try fixture.box.recorded().contains("involvedObject.uid=pod-1"))
    }

    @Test("首次拉取失败即时输出事件，恢复后记录恢复并成功")
    func pullRecovers() async throws {
        let fixture = try ClusterFixture(frames: [ClusterFixture.frame(pods: [ClusterFixture.pod(ClusterFixture.container("ErrImagePull", ready: false))]), ClusterFixture.frame()], event: "registry connection timeout")
        defer { fixture.box.remove() }
        var deployer = fixture.deployer()
        deployer.imagePullGrace = .seconds(5)
        let (result, text) = try await run(fixture, deployer: deployer)
        #expect(result.succeeded)
        #expect(text.contains("registry connection timeout") && text.contains("已恢复就绪"))
    }

    @Test("OOM 与异常终止不必等待 CrashLoopBackOff", arguments: ["OOMKilled", "Error"])
    func terminated(_ reason: String) async throws {
        let fixture = try ClusterFixture(frames: [ClusterFixture.frame(pods: [ClusterFixture.pod(ClusterFixture.container(reason, ready: false, terminated: true))])])
        defer { fixture.box.remove() }
        let (result, text) = try await run(fixture)
        #expect(!result.succeeded && result.message?.contains(reason) == true)
        #expect(text.contains("退出码 137") && text.contains("当前实例启动失败"))
    }

    @Test("初始化容器失败读取对应容器日志；配置错误保留事件", arguments: ["CrashLoopBackOff", "CreateContainerConfigError"])
    func initFailure(_ reason: String) async throws {
        let fixture = try ClusterFixture(frames: [ClusterFixture.frame(pods: [ClusterFixture.pod(ClusterFixture.container(ready: false),
            initStatus: ClusterFixture.container(reason, restarts: reason == "CrashLoopBackOff" ? 2 : 0, ready: false, name: "init-db"))])], event: "secret database-config not found")
        defer { fixture.box.remove() }
        let (result, text) = try await run(fixture)
        #expect(!result.succeeded && text.contains("init-db"))
        if reason == "CrashLoopBackOff" { #expect(try fixture.box.recorded().contains("-c init-db")) }
        else { #expect(text.contains("secret database-config not found")) }
    }

    @Test("部分副本、空列表、零副本、旧 generation 以及同镜像其他工作负载都不能成功", arguments: 0..<5)
    func incomplete(_ kind: Int) async throws {
        let frames: [[String: Any]] = [
            ClusterFixture.frame(replicas: 2, available: 1),
            ClusterFixture.frame(pods: []),
            ClusterFixture.frame(pods: [], replicas: 0, available: 0),
            ClusterFixture.frame(generation: 2, observed: 1),
            ClusterFixture.frame(pods: [ClusterFixture.pod(owner: "other-rs")])
        ]
        let fixture = try ClusterFixture(frames: [frames[kind]])
        defer { fixture.box.remove() }
        var deployer = fixture.deployer(); deployer.settleTimeout = .milliseconds(350)
        let (result, _) = try await run(fixture, deployer: deployer)
        #expect(!result.succeeded)
    }

    @Test("查询失败不再跳过观察并误报成功；错误分类与服务自身崩溃不同")
    func forbidden() async throws {
        let fixture = try ClusterFixture(queryError: "Forbidden: cannot list pods")
        defer { fixture.box.remove() }
        let (result, text) = try await run(fixture)
        #expect(!result.succeeded && result.message?.contains("健康检查未完成") == true)
        #expect(text.contains("Forbidden") && text.contains("第 3/3 次"))
    }

    @Test("读取事件或日志失败不能覆盖原始崩溃原因")
    func diagnosticsDenied() async throws {
        let fixture = try ClusterFixture(frames: [ClusterFixture.frame(pods: [ClusterFixture.pod(ClusterFixture.container("CrashLoopBackOff", restarts: 2, ready: false))])], eventError: true, logError: true)
        defer { fixture.box.remove() }
        let (result, text) = try await run(fixture)
        #expect(!result.succeeded && result.message?.contains("CrashLoopBackOff") == true)
        #expect(text.contains("无权读取事件") && text.contains("读取当前日志失败"))
    }

    @Test("rollout 成功后的新增重启失败，历史重启不误判")
    func restartBaseline() async throws {
        let old = ClusterFixture.frame(pods: [ClusterFixture.pod(ClusterFixture.container(restarts: 5))])
        let stable = try ClusterFixture(frames: [old])
        defer { stable.box.remove() }
        #expect(try await run(stable).0.succeeded)
        let crashed = try ClusterFixture(frames: [old, ClusterFixture.frame(pods: [ClusterFixture.pod(ClusterFixture.container(restarts: 6))])])
        defer { crashed.box.remove() }
        let (result, _) = try await run(crashed)
        #expect(!result.succeeded && result.message?.contains("rollout 完成后崩溃重启") == true)
    }

    @Test("同名 Pod 重建后重新观察，新副本不沿用旧 UID 的重启基线")
    func replacement() async throws {
        let fixture = try ClusterFixture(frames: [ClusterFixture.frame(), ClusterFixture.frame(pods: [ClusterFixture.pod(uid: "pod-2")])])
        defer { fixture.box.remove() }
        #expect(try await run(fixture).0.succeeded)
        #expect(try fixture.box.recorded().components(separatedBy: "args: get pods").count >= 4)
    }

    @Test("后续部署修改模板或重建 Deployment 时不能算本次成功", arguments: [true, false])
    func superseded(_ template: Bool) async throws {
        let fixture = try ClusterFixture(frames: [ClusterFixture.frame(), ClusterFixture.frame(templateChange: template, deploymentUID: template ? "deployment-1" : "deployment-2")])
        defer { fixture.box.remove() }
        let (result, _) = try await run(fixture)
        #expect(!result.succeeded && result.message?.contains("后续变更覆盖") == true)
    }

    @Test("探针失败持续未就绪时展示事件和当前日志；不能把 Running 当成 Ready")
    func unready() async throws {
        let fixture = try ClusterFixture(frames: [ClusterFixture.frame(pods: [ClusterFixture.pod(podReady: false)])])
        defer { fixture.box.remove() }
        var deployer = fixture.deployer(); deployer.settleTimeout = .milliseconds(300)
        let (result, text) = try await run(fixture, deployer: deployer)
        #expect(!result.succeeded)
        #expect(text.contains("Readiness probe failed") && text.contains("当前日志"))
    }

    @Test("多个异常 Pod 均有各自事件及日志")
    func multipleFailures() async throws {
        let c = ClusterFixture.container("CrashLoopBackOff", restarts: 2, ready: false)
        let fixture = try ClusterFixture(frames: [ClusterFixture.frame(pods: [ClusterFixture.pod(c), ClusterFixture.pod(c, name: "demo-second", uid: "pod-2")], replicas: 2, available: 0)])
        defer { fixture.box.remove() }
        let (result, text) = try await run(fixture)
        #expect(result.message?.contains("demo-second") == true)
        #expect(text.contains("Pod demo-second 容器 app 当前日志"))
        #expect(try fixture.box.recorded().contains("involvedObject.uid=pod-2"))
    }

    @Test("未配置探针明确限定验证范围")
    func noProbe() async throws {
        let fixture = try ClusterFixture(frames: [ClusterFixture.frame(probe: false)])
        defer { fixture.box.remove() }
        let (result, _) = try await run(fixture)
        #expect(result.succeeded && result.message?.contains("业务可用性未验证") == true)
    }

    @Test("替换命令失败不运行后续检查")
    func setFailure() async throws {
        let fixture = try ClusterFixture(setError: true)
        defer { fixture.box.remove() }
        let (result, _) = try await run(fixture)
        #expect(result == .failed("kubectl set image 失败：error: 模拟替换失败"))
        #expect(try !fixture.box.recorded().contains("args: get"))
    }

    @Test("取消部署会终止 rollout 进程并清理凭据")
    func cancellation() async throws {
        let fixture = try ClusterFixture(rollout: "exec sleep 60")
        defer { fixture.box.remove() }
        let deployer = fixture.deployer(), log = try fixture.box.log()
        let task = Task { try await deployer.deploy(ClusterFixture.target, image: ClusterFixture.image,
                                                   kubeconfig: Data(ClusterFixture.token.utf8), log: log) }
        let marker = fixture.box.root.appending(path: "rollout.pid")
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.box.root.appending(path: "tmp").path).isEmpty)
    }

    @Test("故障取证超时保留原始原因并终止日志子进程")
    func diagnosticTimeout() async throws {
        let fixture = try ClusterFixture(frames: [ClusterFixture.frame(pods: [ClusterFixture.pod(ClusterFixture.container("CrashLoopBackOff", restarts: 2, ready: false))])],
                                         logScript: "echo $$ > \"$root/log.pid\"; exec sleep 60")
        defer { fixture.box.remove() }
        var deployer = fixture.deployer(); deployer.diagnosticTimeout = .milliseconds(400)
        let (result, text) = try await run(fixture, deployer: deployer)
        #expect(!result.succeeded && result.message?.contains("CrashLoopBackOff") == true)
        #expect(text.contains("故障取证达到时间上限"))
        let pid = try #require(Int32(String(contentsOf: fixture.box.root.appending(path: "log.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0)
    }

    @Test("最新检查失败时不能沿用旧的健康快照成功")
    func noStaleSuccess() async throws {
        let fixture = try ClusterFixture(frames: [ClusterFixture.frame(), ClusterFixture.frame()],
                                         podScript: "[ \"$n\" -gt 0 ] && { echo '连接中断' >&2; exit 1; }")
        defer { fixture.box.remove() }
        let (result, _) = try await run(fixture)
        #expect(!result.succeeded && result.message?.contains("健康检查未完成") == true)
    }

    @Test("扩容的新副本和消失的副本不能绕过稳定观察", arguments: [true, false])
    func replicaChanges(_ scale: Bool) async throws {
        let second = scale
            ? ClusterFixture.frame(pods: [ClusterFixture.pod(), ClusterFixture.pod(ClusterFixture.container(ready: false), name: "demo-second", uid: "pod-2")], replicas: 2, available: 1, generation: 2, observed: 2)
            : ClusterFixture.frame(pods: [])
        let fixture = try ClusterFixture(frames: [ClusterFixture.frame(), second])
        defer { fixture.box.remove() }
        var deployer = fixture.deployer(); deployer.settleTimeout = .milliseconds(500)
        #expect(try await !run(fixture, deployer: deployer).0.succeeded)
    }

    @Test("rollout 超时仍采集未就绪原因和容器日志")
    func rolloutTimeout() async throws {
        let fixture = try ClusterFixture(frames: [ClusterFixture.frame(pods: [ClusterFixture.pod(ClusterFixture.container(ready: false))])],
                                         rollout: "echo 'error: progress deadline exceeded' >&2; exit 1")
        defer { fixture.box.remove() }
        let (result, text) = try await run(fixture)
        #expect(!result.succeeded && result.message?.contains("rollout 没有完成") == true)
        #expect(text.contains("Readiness probe failed") && text.contains("当前实例启动失败"))
    }

    @Test("没有 Pod 时采集控制器告警，定位配额和创建失败")
    func noPodsEvents() async throws {
        let fixture = try ClusterFixture(frames: [ClusterFixture.frame(pods: [])], event: "FailedCreate: exceeded quota")
        defer { fixture.box.remove() }
        var deployer = fixture.deployer(); deployer.settleTimeout = .milliseconds(200)
        let (result, text) = try await run(fixture, deployer: deployer)
        #expect(!result.succeeded)
        #expect(text.contains("ReplicaSet demo-rs 告警") && text.contains("exceeded quota"))
    }

    @Test("长事件末尾的权限根因不会被截掉，登记的令牌不进入日志")
    func longEventAndSecrets() async throws {
        let event = "Failed to pull image " + String(repeating: "long-registry-path/", count: 25)
            + " unauthorized: token " + ClusterFixture.token
        let fixture = try ClusterFixture(frames: [ClusterFixture.frame(pods: [ClusterFixture.pod(ClusterFixture.container("ImagePullBackOff", ready: false))])], event: event)
        defer { fixture.box.remove() }
        let (result, text) = try await run(fixture)
        #expect(!result.succeeded && result.message?.contains("unauthorized") == true)
        #expect(text.contains("unauthorized") && !text.contains(ClusterFixture.token))
        #expect(text.contains("[已隐藏]"))
    }

    @Test("上次 OOM 尚未恢复时及时失败；初始化容器正常完成不误判")
    func previousOOM() throws {
        var status = ClusterFixture.container(restarts: 1, ready: false)
        status["lastState"] = ["terminated": ["reason": "OOMKilled", "exitCode": 137]]
        let pod = try JSONDecoder().decode(Pod.self, from: JSONSerialization.data(withJSONObject: ClusterFixture.pod(status)))
        #expect(PodInspector.failures(of: pod).first?.reason == "OOMKilled")
        let completed: [String: Any] = ["name": "init-db", "state": ["terminated": ["reason": "Completed", "exitCode": 0]]]
        let ready = try JSONDecoder().decode(Pod.self, from: JSONSerialization.data(withJSONObject: ClusterFixture.pod(initStatus: completed)))
        #expect(PodInspector.failures(of: ready).isEmpty)
    }

    @Test("从输出摘要提取 panic 或 error，不用日志文字决定运行状态")
    func keyLine() {
        #expect(OutputTail.keyLine(in: "panic: 数据库连接失败\ngoroutine 1\nmain.go:9") == "panic: 数据库连接失败")
        #expect(OutputTail.keyLine(in: "启动\nError: 配置缺失\n退出") == "Error: 配置缺失")
    }

    @Test("找不到 kubectl 时不创建凭据文件")
    func missingKubectl() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let log = try box.log()
        let deployer = KubeDeployer(stage: box.stage(), temporaryDirectory: box.root.appending(path: "tmp"))
        #expect(try await deployer.deploy(ClusterFixture.target, image: ClusterFixture.image, kubeconfig: Data(), log: log) == .failed("找不到 kubectl"))
    }
}
