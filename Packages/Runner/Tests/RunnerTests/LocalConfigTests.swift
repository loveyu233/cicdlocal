import Foundation
import Testing
@testable import Runner

@Suite("新版多镜像配置")
struct LocalConfigTests {
    static let sample = """
        test: [make test]
        build:
          parallel: 2
          images:
            - {name: app, image: 'r.invalid/app:${BRANCH}-${SHA}', command: 'make push TAG=${TIME}'}
            - {name: worker, image: 'r.invalid/worker:${TIME}', dockerfile: Dockerfile, platform: linux/amd64}
        deploy:
          - name: 测试发布
            branches: [dev, main]
            k8s: 测试
            parallel: 2
            targets:
              - {build: app, namespace: ns, deployment: app, container: app}
              - {build: worker, namespace: ns, deployment: worker, container: app}
          - name: 正式发布
            branches: [main]
            k8s: 正式
            confirm: true
            targets:
              - {build: app, namespace: ns, deployment: app, container: app}
        """
    func parse(_ text: String) throws -> LocalConfig { try LocalConfig.parse(Data(text.utf8)) }
    func error(_ text: String) -> String { do { _ = try parse(text); return "" } catch { return "\(error)" } }

    @Test("多分支、多镜像、批次顺序及默认值")
    func sample() throws {
        let config = try parse(Self.sample)
        #expect(config.build.images.count == 2 && config.build.parallel == 2)
        #expect(config.deploy.map(\.name) == ["测试发布", "正式发布"])
        #expect(config.deploy.last?.parallel == 1 && config.deploy.last?.confirm == true)
        #expect(config.connectionNames == ["正式", "测试"])
        let vars = RunVariables(commit: "abcdef0123456789", branch: "main")
        let plan = try #require(config.plan(branch: "main", variables: vars))
        #expect(plan.images.map(\.name) == ["app", "worker"])
        #expect(plan.batches.count == 2)
        #expect(plan.images.first?.image == "r.invalid/app:main-abcdef012345")
        #expect(plan.environment["CICD_IMAGE"] == nil)
        #expect(!plan.isDeployable)
        #expect(config.plan(branch: "feature", variables: vars) == nil)
        #expect(try JSONDecoder().decode(RunPlan.self, from: JSONEncoder().encode(plan)) == plan)
    }

    @Test("只构建命中分支引用的镜像，单项使用相同结构")
    func selected() throws {
        let text = Self.sample.replacingOccurrences(of: "branches: [dev, main]", with: "branches: [dev]")
        let plan = try #require(try parse(text).plan(branch: "main", variables: RunVariables(commit: "abc", branch: "main")))
        #expect(plan.images.map(\.name) == ["app"])
        #expect(plan.batches.map(\.name) == ["正式发布"])
        #expect(try parse(Self.sample.replacingOccurrences(of: "test: [make test]\n", with: "")).test.isEmpty)
    }

    @Test("拒绝旧格式、未知字段、空列表和无效并发", arguments: [
        ("test: [make test]", "test: make test", "test 必须"),
        ("parallel: 2", "parallel: 0", "parallel 必须"),
        ("parallel: 2", "parallel: 2.5", "parallel 必须"),
        ("parallel: 2", "parallel: 51", "parallel 必须"),
        ("branches: [dev, main]", "branches: []", "branches 必须"),
        ("branches: [dev, main]", "branches: [dev, dev]", "重复"),
        ("branches: [dev, main]", "branch: dev", "无法识别"),
        ("branches: [dev, main]", "branches: [refs/heads/dev]", "直接写分支名"),
        ("name: worker", "name: app", "构建名称重复"),
        ("name: 正式发布", "name: 测试发布", "批次名称重复"),
        ("build: worker", "build: missing", "不存在的构建"),
        ("dockerfile: Dockerfile", "dockerfile: ../Dockerfile", "项目内的相对路径"),
        ("dockerfile: Dockerfile", "dockerfile: Dockerfile, command: make", "二选一"),
        ("dockerfile: Dockerfile", "command: make", "platform 只用于"),
        ("confirm: true", "confirm: 是", "confirm 只能"),
        ("confirm: true", "confirm: yes", "confirm 只能"),
        ("namespace: ns", "namespace: Wrong", "namespace 只能"),
        ("${SHA}", "${OTHER}", "image 格式"),
        ("deployment: worker", "deployment: app", "重复写了同一个替换目标"),
        ("k8s: 正式", "k8s: 测试", "重复写了同一个替换目标")
    ])
    func invalid(change: (String, String, String)) {
        #expect(error(Self.sample.replacingOccurrences(of: change.0, with: change.1)).contains(change.2))
    }

    @Test("配置大小、重复字段、别名、多文档、深层嵌套的保护")
    func yamlSafety() {
        #expect(error("build: {image: a, command: make}").contains("无法识别"))
        #expect(error(Self.sample + "\nbuild: {}\n").contains("重复"))
        #expect(error("test: &x [a]\nbuild: *x\n").contains("别名"))
        #expect(error(Self.sample + "\n---\nbuild: {}\n").contains("只能包含一个 YAML 文档"))
        #expect(error("").contains("为空"))
        #expect(error("build: [\n").contains("YAML 语法错误"))
        #expect(error(String(repeating: "#", count: LocalConfig.maximumBytes + 1)).contains("64 KiB"))
        #expect(error("test: " + String(repeating: "[", count: 990) + String(repeating: "]", count: 990)).contains("嵌套超过 16 层"))
        #expect(error("test: [" + Array(repeating: "x", count: 20_001).joined(separator: ",") + "]").contains("节点"))
    }

    @Test("变量冻结为北京时间秒、12 位 SHA；digest 引用保留仓库端口")
    func variables() {
        let variables = RunVariables(date: Date(timeIntervalSince1970: 1_792_626_600), commit: "ABCDEF0123456789", branch: "feature/新功能 #1")
        #expect(variables.time == "20261022.075000")
        #expect(variables.sha == "abcdef012345")
        #expect(variables.branch == "feature------1")
        #expect(variables.expand("${SHA}-${HOME}") == "abcdef012345-${HOME}")
        let image = RunPlan.Image(name: "app", image: "127.0.0.1:5000/demo:v1", build: .command("make"), digest: "sha256:" + String(repeating: "a", count: 64))
        #expect(image.reference == "127.0.0.1:5000/demo@sha256:" + String(repeating: "a", count: 64))
    }
}
