import Foundation

/// 保留完整 Pod 模板的 spec，避免只比较镜像而漏掉命令、环境变量等后续变更。
indirect enum KubeJSON: Decodable, Equatable, Sendable {
    case object([String: KubeJSON]), array([KubeJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode([String: KubeJSON].self) { self = .object(item) }
        else { self = .array(try value.decode([KubeJSON].self)) }
    }
}

struct ResourceMetadata: Decodable, Sendable {
    struct Owner: Decodable, Sendable {
        var uid: String
        var kind: String
        var controller: Bool?
    }
    var name: String
    var uid: String?
    var generation: Int?
    var deletionTimestamp: String?
    var ownerReferences: [Owner]?

    func owned(by uid: String, kind: String) -> Bool {
        ownerReferences?.contains { $0.uid == uid && $0.kind == kind && $0.controller == true } == true
    }
}

struct DeploymentInfo: Decodable, Sendable {
    struct Spec: Decodable, Sendable {
        var replicas: Int?
        var selector: Selector
        var template: Template
    }
    struct Selector: Decodable, Sendable {
        struct Expression: Decodable, Sendable {
            var key: String
            var `operator`: String
            var values: [String]?
        }
        var matchLabels: [String: String]?
        var matchExpressions: [Expression]?
    }
    struct Template: Decodable, Sendable, Equatable {
        struct Metadata: Decodable, Sendable {
            var labels: [String: String]?
            var annotations: [String: String]?
        }
        var metadata: Metadata?
        var spec: PodSpec

        static func == (lhs: Self, rhs: Self) -> Bool {
            // ReplicaSet 会注入 pod-template-hash，除此之外的模板差异都不能忽略。
            func labels(_ value: Self) -> [String: String] {
                (value.metadata?.labels ?? [:]).filter { $0.key != "pod-template-hash" }
            }
            return lhs.spec.raw == rhs.spec.raw && labels(lhs) == labels(rhs)
                && (lhs.metadata?.annotations ?? [:]) == (rhs.metadata?.annotations ?? [:])
        }
    }
    struct PodSpec: Decodable, Sendable {
        var containers: [Container]
        var raw: KubeJSON
        enum CodingKeys: String, CodingKey { case containers }
        init(from decoder: any Decoder) throws {
            raw = try KubeJSON(from: decoder)
            containers = try decoder.container(keyedBy: CodingKeys.self).decode([Container].self, forKey: .containers)
        }
    }
    struct Container: Decodable, Sendable {
        var name: String
        var image: String?
        var readinessProbe: KubeJSON?
    }
    struct Status: Decodable, Sendable {
        var observedGeneration: Int?
        var replicas: Int?
        var updatedReplicas: Int?
        var readyReplicas: Int?
        var availableReplicas: Int?
        var unavailableReplicas: Int?
        var conditions: [Pod.Condition]?
    }
    var metadata: ResourceMetadata
    var spec: Spec
    var status: Status?

    var labelSelector: String {
        var parts = (spec.selector.matchLabels ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        for expression in spec.selector.matchExpressions ?? [] {
            switch expression.operator {
            case "In": parts.append("\(expression.key) in (\((expression.values ?? []).joined(separator: ",")))")
            case "NotIn": parts.append("\(expression.key) notin (\((expression.values ?? []).joined(separator: ",")))")
            case "Exists": parts.append(expression.key)
            case "DoesNotExist": parts.append("!\(expression.key)")
            default: break
            }
        }
        return parts.joined(separator: ",")
    }

    func hasReadinessProbe(_ name: String) -> Bool {
        spec.template.spec.containers.first { $0.name == name }?.readinessProbe != nil
    }
}

struct ReplicaSetList: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        struct Spec: Decodable, Sendable { var template: DeploymentInfo.Template }
        var metadata: ResourceMetadata
        var spec: Spec
    }
    var items: [Item]
}

struct DeploymentSnapshot: Sendable {
    var deployment: DeploymentInfo
    var replicas: [ReplicaSetList.Item]
    var pods: [Pod]
    var expected: Int { deployment.spec.replicas ?? 1 }

    func complete(container: String) -> Bool {
        guard expected > 0, let generation = deployment.metadata.generation,
              let status = deployment.status, (status.observedGeneration ?? 0) >= generation,
              status.updatedReplicas == expected, status.replicas == expected,
              (status.readyReplicas ?? 0) >= expected, (status.availableReplicas ?? 0) >= expected,
              (status.unavailableReplicas ?? 0) == 0, pods.count == expected else { return false }
        return PodInspector.unready(pods, container: container).isEmpty
    }

    var summary: String {
        "期望 \(expected) 个副本，已更新 \(deployment.status?.updatedReplicas ?? 0)，可用 \(deployment.status?.availableReplicas ?? 0)，本次目标 Pod \(pods.count) 个"
    }
}

struct DeploymentChanged: Error, Sendable, CustomStringConvertible {
    var description = "本次部署已被后续变更覆盖，或目标 Deployment 已被删除重建"
}
