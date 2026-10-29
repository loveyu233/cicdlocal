import Foundation
import Yams

public struct ConfigError: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// 新版配置统一以镜像列表和独立部署批次表达；未知字段与旧语法在执行前拒绝。
public struct LocalConfig: Sendable, Equatable, Codable {
    public static let path = ".local.cicd.yml"
    public static let maximumBytes = 64 * 1_024

    public struct Build: Sendable, Equatable, Codable {
        public var name: String
        public var image: String
        public var dockerfile: String?
        public var command: String?
        public var platform: String?
    }

    public struct Builds: Sendable, Equatable, Codable {
        public var parallel: Int
        public var images: [Build]
    }

    /// 批次属性在解析时附到目标上，集群执行器不需要重新理解配置树。
    public struct Target: Sendable, Hashable, Codable {
        public var branch: String
        public var k8s: String
        public var namespace: String
        public var deployment: String
        public var container: String
        public var confirm: Bool
        public var build: String
        public var batch: String

        public init(branch: String = "", k8s: String, namespace: String, deployment: String, container: String,
                    confirm: Bool = false, build: String = "app", batch: String = "") {
            self.branch = branch; self.k8s = k8s; self.namespace = namespace
            self.deployment = deployment; self.container = container; self.confirm = confirm
            self.build = build; self.batch = batch
        }
        public var key: String { "\(k8s)\n\(namespace)\n\(deployment)\n\(container)" }
        public var stageKey: String { "deploy\n\(batch)\n\(key)" }
        public var summary: String { "\(batch) · \(build) · \(namespace)/\(deployment)/\(container)" }
    }

    public struct Batch: Sendable, Equatable, Codable {
        public var name: String
        public var branches: [String]
        public var k8s: String
        public var confirm: Bool
        public var parallel: Int
        public var targets: [Target]
    }

    public var test: [String]
    public var build: Builds
    public var deploy: [Batch]
    public var targets: [Target] { deploy.flatMap(\.targets) }
    public var connectionNames: [String] { Array(Set(deploy.map(\.k8s))).sorted() }

    public static func parse(_ data: Data) throws -> LocalConfig {
        guard data.count <= maximumBytes else { throw ConfigError("配置文件超过 64 KiB") }
        guard let source = String(data: data, encoding: .utf8), !source.utf8.contains(0) else {
            throw ConfigError("配置文件不是 UTF-8 文本")
        }
        let root: Node?
        do { root = try SafeYAML.compose(source) }
        catch let error as SafeYAMLError { throw ConfigError(error.description) }
        catch YamlError.duplicatedKeysInMapping(let duplicates, let context) {
            throw ConfigError("第 \(context.mark.line) 行开始的映射里字段 \(duplicates.sorted().joined(separator: "、")) 重复")
        } catch { throw ConfigError("YAML 格式错误：\(error)") }
        guard let root else { throw ConfigError("配置文件为空") }
        let top = try fields(root, of: "配置", allowed: ["test", "build", "deploy"])
        let tests: [String]
        if let node = top["test"] {
            guard let sequence = node.sequence, sequence.count <= 50 else { throw ConfigError(at(node) + "test 必须是最多 50 条命令的列表") }
            tests = try sequence.map { try text(of: $0, field: "test 命令") }
        } else { tests = [] }
        guard let buildNode = top["build"] else { throw ConfigError("缺少 build") }
        let buildFields = try fields(buildNode, of: "build", allowed: ["parallel", "images"])
        let imageNodes = try list(buildFields["images"], field: "build.images", parent: buildNode)
        var images: [Build] = []
        for node in imageNodes {
            let item = try fields(node, of: "镜像", allowed: ["name", "image", "command", "dockerfile", "platform"])
            let name = try identifier(required(item["name"], "name", in: node))
            guard !images.contains(where: { $0.name == name }) else { throw ConfigError(at(node) + "构建名称重复：\(name)") }
            let build = Build(name: name, image: try image(required(item["image"], "image", in: node)),
                              dockerfile: try item["dockerfile"].map { try dockerfile(text(of: $0, field: "dockerfile"), node: $0) },
                              command: try item["command"].map { try text(of: $0, field: "command") },
                              platform: try item["platform"].map { try platform(text(of: $0, field: "platform"), node: $0) })
            guard (build.dockerfile == nil) != (build.command == nil) else { throw ConfigError(at(node) + "dockerfile 和 command 必须二选一") }
            guard build.command == nil || build.platform == nil else { throw ConfigError(at(node) + "platform 只用于 dockerfile") }
            images.append(build)
        }
        var batches: [Batch] = []
        var destinations: Set<String> = []
        var totalTargets = 0
        for node in try list(top["deploy"], field: "deploy", parent: root) {
            let item = try fields(node, of: "部署批次", allowed: ["name", "branches", "k8s", "confirm", "parallel", "targets"])
            let name = try connection(required(item["name"], "name", in: node))
            guard !batches.contains(where: { $0.name == name }) else { throw ConfigError(at(node) + "批次名称重复：\(name)") }
            let branches = try list(item["branches"], field: "branches", parent: node).map { try branch((text(of: $0, field: "branches"), $0)) }
            guard Set(branches).count == branches.count else { throw ConfigError(at(node) + "branches 包含重复分支") }
            let k8s = try connection(required(item["k8s"], "k8s", in: node))
            let limit = try parallel(item["parallel"])
            var confirm = false
            if let value = item["confirm"] {
                guard let scalar = value.scalar, ["true", "false"].contains(scalar.string), let flag = value.bool else { throw ConfigError(at(value) + "confirm 只能写 true 或 false") }
                confirm = flag
            }
            var targets: [Target] = []
            var workloads: Set<String> = []
            for targetNode in try list(item["targets"], field: "targets", parent: node) {
                let targetFields = try fields(targetNode, of: "替换目标", allowed: ["build", "namespace", "deployment", "container"])
                let ref = try required(targetFields["build"], "build", in: targetNode).value
                guard images.contains(where: { $0.name == ref }) else { throw ConfigError(at(targetNode) + "引用了不存在的构建：\(ref)") }
                let target = Target(branch: branches.joined(separator: "、"), k8s: k8s,
                                    namespace: try kubernetesName(required(targetFields["namespace"], "namespace", in: targetNode), field: "namespace"),
                                    deployment: try kubernetesName(required(targetFields["deployment"], "deployment", in: targetNode), field: "deployment"),
                                    container: try kubernetesName(required(targetFields["container"], "container", in: targetNode), field: "container"),
                                    confirm: confirm, build: ref, batch: name)
                for branch in branches {
                    guard destinations.insert(branch + "\n" + target.key).inserted else {
                        throw ConfigError(at(targetNode) + "分支 \(branch) 重复写了同一个替换目标")
                    }
                }
                let workload = target.namespace + "/" + target.deployment
                guard workloads.insert(workload).inserted || limit == 1 else {
                    throw ConfigError(at(targetNode) + "同一 Deployment 的多个容器不能并行替换，请将该批次 parallel 设为 1")
                }
                targets.append(target)
            }
            totalTargets += targets.count
            guard totalTargets <= 50 else { throw ConfigError("deploy 总共最多 50 个替换目标") }
            batches.append(Batch(name: name, branches: branches, k8s: k8s, confirm: confirm, parallel: limit, targets: targets))
        }
        return LocalConfig(test: tests, build: Builds(parallel: try parallel(buildFields["parallel"]), images: images), deploy: batches)
    }

    private static func list(_ node: Node?, field: String, parent: Node) throws -> [Node] {
        guard let node, let list = node.sequence, !list.isEmpty, list.count <= 50 else {
            throw ConfigError(at(node ?? parent) + "\(field) 必须是 1 至 50 项的列表")
        }
        return Array(list)
    }

    private static func parallel(_ node: Node?) throws -> Int {
        guard let node else { return 1 }
        guard node.scalar != nil, let n = node.int, (1...50).contains(n) else {
            throw ConfigError(at(node) + "parallel 必须是 1 至 50 的整数")
        }
        return n
    }

    private static func identifier(_ field: Located) throws -> String {
        guard (try? #/[A-Za-z][A-Za-z0-9_-]{0,63}/#.wholeMatch(in: field.value)) != nil else {
            throw ConfigError(at(field.node) + "构建 name 必须以字母开头，只含字母、数字、下划线和连字符，最多 64 位")
        }
        return field.value
    }

    // MARK: - 字段读取

    private typealias Located = (value: String, node: Node)

    private static func at(_ node: Node) -> String { node.mark.map { "第 \($0.line) 行：" } ?? "" }

    private static func fields(_ node: Node, of name: String, allowed: Set<String>) throws -> [String: Node] {
        guard let mapping = node.mapping else { throw ConfigError(at(node) + "\(name)应当是键值对") }
        var result: [String: Node] = [:]
        for (key, value) in mapping {
            guard let name = key.scalar?.string else { throw ConfigError(at(key) + "字段名必须是文本") }
            guard allowed.contains(name) else {
                throw ConfigError(at(key) + "无法识别的字段 \(name)，可用字段：\(allowed.sorted().joined(separator: "、"))")
            }
            guard result.updateValue(value, forKey: name) == nil else { throw ConfigError(at(key) + "字段 \(name) 重复") }
        }
        return result
    }

    private static func text(of node: Node, field: String) throws -> String {
        guard let scalar = node.scalar, node.null == nil else { throw ConfigError(at(node) + "\(field) 应当是一行文本") }
        let value = scalar.string
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigError(at(node) + "\(field) 不能为空") }
        return value
    }

    private static func required(_ node: Node?, _ field: String, in parent: Node) throws -> Located {
        guard let node else { throw ConfigError(at(parent) + "缺少 \(field)") }
        return (try text(of: node, field: field).trimmingCharacters(in: .whitespaces), node)
    }

    private static func image(_ field: Located) throws -> String {
        let value = field.value
        let bare = RunVariables.names.reduce(value) { $0.replacingOccurrences(of: "${\($1)}", with: "x") }
        guard value.utf8.count <= 512, (try? #/[A-Za-z0-9][A-Za-z0-9._\/:@-]*/#.wholeMatch(in: bare)) != nil else {
            throw ConfigError(at(field.node) + "image 格式不正确，只能使用 ${TIME}、${SHA}、${BRANCH} 三个变量")
        }
        return value
    }

    private static func dockerfile(_ value: String, node: Node) throws -> String {
        let path = value.trimmingCharacters(in: .whitespaces)
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !path.hasPrefix("~"), !parts.contains(".."), path.utf8.count <= 1_024 else {
            throw ConfigError(at(node) + "dockerfile 必须是项目内的相对路径")
        }
        return path
    }

    private static func platform(_ value: String, node: Node) throws -> String {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard (try? #/[A-Za-z0-9._/,-]{1,128}/#.wholeMatch(in: value)) != nil else {
            throw ConfigError(at(node) + "platform 格式不正确，例如 linux/amd64")
        }
        return value
    }

    private static func branch(_ field: Located) throws -> String {
        let value = field.value
        guard !value.hasPrefix("refs/") else { throw ConfigError(at(field.node) + "branch 直接写分支名，例如 main") }
        guard value.utf8.count <= 255, !value.hasPrefix("-"), !value.contains(".."),
              !value.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 0x20 || "~^:?*[\\".unicodeScalars.contains($0) }) else {
            throw ConfigError(at(field.node) + "branch 不是有效的分支名")
        }
        return value
    }

    private static func connection(_ field: Located) throws -> String {
        guard field.value.count <= 64, !field.value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw ConfigError(at(field.node) + "k8s 连接名最多 64 个字符")
        }
        return field.value
    }

    private static func kubernetesName(_ field: Located, field name: String) throws -> String {
        guard (try? #/[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?/#.wholeMatch(in: field.value)) != nil else {
            throw ConfigError(at(field.node) + "\(name) 只能包含小写字母、数字、- 和 .")
        }
        return field.value
    }
}
