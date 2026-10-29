import Darwin
import Foundation
import Runner
import Security
import Yams

public struct KubeconfigError: Error, Sendable, CustomStringConvertible {
    public let description: String
    init(_ message: String) { description = message }
}

/// 预览只公开非凭据信息。配置正文只写入钥匙串，不参与描述、日志或数据库。
public struct KubeconfigPreview: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let context: String
    public let server: String
    public let namespace: String
    public let warnings: [String]
    public let certificateExpiresAt: Date?
    public var byteCount: Int { payload.count }
    /// 只含选定 context 的 kubeconfig（JSON 形式），证书和令牌文件已内嵌。
    let payload: Data
    public var description: String { "kubeconfig 导入预览（\(byteCount) 字节，正文已隐藏）" }
    public var debugDescription: String { description }
}

public struct KubeconfigDocument: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let contexts: [String]
    public let currentContext: String?
    /// 只保存原文：Yams 的 Node 不是 Sendable，预览时重新解析。
    private let text: String
    private let directory: URL
    public var description: String { "kubeconfig（\(contexts.count) 个 context，正文已隐藏）" }
    public var debugDescription: String { description }

    public static func read(_ url: URL) throws -> Self {
        let data = try readFile(url, limit: 1 << 20)
        guard let text = String(data: data, encoding: .utf8) else { throw KubeconfigError("kubeconfig 必须是 UTF-8 文本。") }
        do {
            let root = try compose(text)
            let entries = try named(root["contexts"], field: "context")
            guard !entries.isEmpty else { throw KubeconfigError("配置没有可选择的 context。") }
            let current = try optionalString(root["current-context"])
            return Self(contexts: entries.keys.sorted(), currentContext: current.flatMap { entries[$0] == nil ? nil : $0 },
                        text: text, directory: url.deletingLastPathComponent())
        } catch let error as KubeconfigError { throw error }
        catch { throw invalidSyntax }
    }

    // YAML 诊断可能包含凭据片段，不能透传解析器原始错误。
    private static let invalidSyntax = KubeconfigError("kubeconfig 语法无效、键重复或超出解析限制；原始内容未写入诊断。")

    private static func compose(_ text: String) throws -> Node {
        let root: Node?
        do { root = try SafeYAML.compose(text, maxDepth: 30, maxNodes: 20_000) } catch { throw invalidSyntax }
        guard let root, root.mapping != nil, root.tagName == .map,
              try string(root["apiVersion"]) == "v1", try string(root["kind"]) == "Config"
        else { throw KubeconfigError("只支持 apiVersion: v1、kind: Config 的单文档 kubeconfig。") }
        return root
    }

    public func preview(context name: String) throws -> KubeconfigPreview {
        try Task.checkCancellation()
        let root = try Self.compose(text)
        guard let context = try Self.named(root["contexts"], field: "context")[name] else {
            throw KubeconfigError("选定的 context 已不存在。")
        }
        try Self.keys(context, allowed: ["cluster", "user", "namespace"], owner: "context")
        let clusterName = try Self.string(context["cluster"])
        let userName = try Self.optionalString(context["user"]) ?? ""
        let namespace = try Self.optionalString(context["namespace"]) ?? "default"
        guard let cluster = try Self.named(root["clusters"], field: "cluster")[clusterName] else {
            throw KubeconfigError("选定 context 引用的集群不存在。")
        }
        let user = try Self.named(root["users"], field: "user")[userName]
        guard userName.isEmpty || user != nil else { throw KubeconfigError("选定 context 引用的用户不存在。") }
        try Self.keys(cluster, allowed: ["server", "tls-server-name", "insecure-skip-tls-verify", "certificate-authority",
                                         "certificate-authority-data", "proxy-url", "disable-compression"], owner: "cluster")
        let server = try Self.string(cluster["server"])
        guard let address = URLComponents(string: server), ["https", "http"].contains(address.scheme),
              let host = address.host, !host.isEmpty, address.user == nil, address.password == nil,
              address.query == nil, address.fragment == nil
        else { throw KubeconfigError("集群地址必须是有效 HTTP(S) 地址，且不能包含内嵌凭据或查询参数。") }
        var warnings: [String] = []
        if host == "localhost" || host == "::1" || host == "[::1]" || host.hasPrefix("127.") {
            warnings.append("集群使用本机回环地址，请确认 kubectl 在本机能连接。")
        }
        var clusterValue: [String: Any] = ["server": server]
        for key in ["tls-server-name", "proxy-url"] {
            if let value = try Self.optionalString(cluster[key]) { clusterValue[key] = value }
        }
        for key in ["insecure-skip-tls-verify", "disable-compression"] {
            if let node = cluster[key] { clusterValue[key] = try Self.boolean(node) }
        }
        if address.scheme == "http" || (clusterValue["insecure-skip-tls-verify"] as? Bool) == true {
            warnings.append("此配置未启用完整的 TLS 服务器验证，请确认用途。")
        }
        try embed(cluster, file: "certificate-authority", data: "certificate-authority-data", into: &clusterValue)
        var userValue: [String: Any] = [:]
        var expires: Date?
        if let user {
            try Self.keys(user, allowed: ["token", "tokenFile", "username", "password", "client-certificate",
                                          "client-certificate-data", "client-key", "client-key-data", "exec"], owner: "user")
            for key in ["token", "username", "password"] {
                if let value = try Self.optionalString(user[key]) { userValue[key] = value }
            }
            // tokenFile 在 client-go 中优先于 token；冻结当前内容，不保留宿主机文件路径。
            if let path = try Self.optionalString(user["tokenFile"]), !path.isEmpty {
                guard let value = String(data: try attachment(path), encoding: .utf8) else {
                    throw KubeconfigError("tokenFile 必须是 UTF-8 文本。")
                }
                userValue["token"] = value.trimmingCharacters(in: .whitespacesAndNewlines)
                warnings.append("tokenFile 已冻结为当前值；外部令牌刷新后需重新导入。")
            }
            try embed(user, file: "client-certificate", data: "client-certificate-data", into: &userValue)
            try embed(user, file: "client-key", data: "client-key-data", into: &userValue)
            if let certificate = userValue["client-certificate-data"] as? String, let data = Data(base64Encoded: certificate) {
                expires = Self.expiration(data)
                if let expires, expires.timeIntervalSinceNow < 30 * 86_400 {
                    warnings.append(expires < Date() ? "客户端证书已过期。" : "客户端证书将在 30 天内过期。")
                } else if expires == nil { warnings.append("未能读取客户端证书有效期，请另行核实。") }
            }
            if let exec = user["exec"] {
                userValue["exec"] = try Self.execConfiguration(exec)
                warnings.append("配置使用 exec 认证插件；需要本机 PATH 中有对应命令。导入时不会执行它。")
            }
        }
        var selectedContext = ["cluster": clusterName, "namespace": namespace]
        if !userName.isEmpty { selectedContext["user"] = userName }
        let output: [String: Any] = [
            "apiVersion": "v1", "kind": "Config", "current-context": name,
            "contexts": [["name": name, "context": selectedContext]],
            "clusters": [["name": clusterName, "cluster": clusterValue]],
            "users": userName.isEmpty ? [] : [["name": userName, "user": userValue]],
        ]
        // JSON 是 kubeconfig 接受的 YAML 子集，避免自行实现凭据字符串的 YAML 转义。
        let payload = try JSONSerialization.data(withJSONObject: output, options: Self.writingOptions)
        guard payload.count <= 65_536 else { throw KubeconfigError("选定配置超过 64 KiB 上限，请缩小配置。") }
        let displayAddress = "\(address.scheme ?? "https")://\(host)" + (address.port.map { ":\($0)" } ?? "")
        return KubeconfigPreview(context: name, server: displayAddress, namespace: namespace, warnings: warnings,
                                 certificateExpiresAt: expires, payload: payload)
    }

    /// kubectl 用 YAML 解析器读取，不认识 JSON 默认的 `\/` 转义（报 found unknown escape character），所以斜杠不转义。
    private static let writingOptions: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]

    /// 早期版本导入的连接在钥匙串里带 `\/` 转义；交给 kubectl 前重新写一遍，不用重新导入。
    static func kubectlReadable(_ payload: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: payload),
              let data = try? JSONSerialization.data(withJSONObject: object, options: writingOptions) else { return payload }
        return data
    }

    private func embed(_ node: Node, file: String, data: String, into result: inout [String: Any]) throws {
        if let value = try Self.optionalString(node[data]), !value.isEmpty {
            guard let decoded = Data(base64Encoded: value), !decoded.isEmpty else { throw KubeconfigError("内嵌证书或密钥的 Base64 格式无效。") }
            result[data] = value
        } else if let path = try Self.optionalString(node[file]), !path.isEmpty {
            result[data] = try attachment(path).base64EncodedString()
        }
    }
    private func attachment(_ path: String) throws -> Data {
        guard !path.contains("\0"), !path.hasPrefix("~") else {
            throw KubeconfigError("证书或令牌路径无效；请使用绝对路径或相对于 kubeconfig 的路径。")
        }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appending(path: path)
        return try Self.readFile(url, limit: 65_536)
    }
    private static func readFile(_ url: URL, limit: Int) throws -> Data {
        // 非阻塞打开后核实普通文件，防止设备/FIFO 阻塞界面或产生无限输入。
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw KubeconfigError("无法读取所选配置或引用文件，请检查文件权限。") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else {
            throw KubeconfigError("配置或引用文件不是普通文件，或超过导入大小限制。")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw KubeconfigError("读取配置或引用文件失败。")
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw KubeconfigError("配置或引用文件超过导入大小限制。") }
        }
        return data
    }
    private static func named(_ node: Node?, field: String) throws -> [String: Node] {
        guard let node else { return [:] }
        guard let values = node.sequence, node.tagName == .seq else { throw KubeconfigError("kubeconfig 的命名条目必须是列表。") }
        var result: [String: Node] = [:]
        for value in values {
            try keys(value, allowed: ["name", field], owner: "命名条目")
            let name = try string(value["name"])
            guard !name.isEmpty, result[name] == nil, let item = value[field], item.mapping != nil, item.tagName == .map else {
                throw KubeconfigError("kubeconfig 的条目名称重复、为空或缺少内容。")
            }
            result[name] = item
        }
        return result
    }
    private static func keys(_ node: Node, allowed: Set<String>, owner: String) throws {
        guard node.tagName == .map, let pairs = node.mapping,
              pairs.allSatisfy({ $0.key.tagName == .str && allowed.contains($0.key.scalar?.string ?? "") })
        else { throw KubeconfigError("\(owner) 含不支持的字段、标签或 YAML 合并键；请简化后导入。") }
    }
    /// Yams 会给未加引号的文本推断类型；这些类型都按原文读取，保留数字形态的令牌、用户名及 namespace。
    private static let textTags: Set<Tag.Name> = [.str, .int, .float, .bool, .timestamp]

    private static func string(_ node: Node?) throws -> String {
        guard let node, let scalar = node.scalar, textTags.contains(node.tagName),
              !scalar.string.contains("\0") else { throw KubeconfigError("kubeconfig 的文本字段格式无效。") }
        return scalar.string
    }
    /// 缺少或写成 null 都视为没有填写。
    private static func optionalString(_ node: Node?) throws -> String? {
        guard let node, node.tagName != .null else { return nil }
        return try string(node)
    }
    private static func boolean(_ node: Node) throws -> Bool {
        guard node.scalar != nil, node.tagName == .bool, let value = node.bool else { throw KubeconfigError("kubeconfig 的布尔字段格式无效。") }
        return value
    }
    private static func execConfiguration(_ node: Node) throws -> [String: Any] {
        try keys(node, allowed: ["apiVersion", "command", "args", "env", "installHint", "provideClusterInfo", "interactiveMode"], owner: "exec")
        var result: [String: Any] = ["command": try string(node["command"])]
        for key in ["apiVersion", "installHint", "interactiveMode"] {
            if let value = try optionalString(node[key]) { result[key] = value }
        }
        if let args = node["args"] {
            guard let values = args.sequence, args.tagName == .seq else { throw KubeconfigError("exec.args 必须是文本列表。") }
            result["args"] = try values.map { try string($0) }
        }
        if let env = node["env"] {
            guard let values = env.sequence, env.tagName == .seq else { throw KubeconfigError("exec.env 必须是名称和值的列表。") }
            result["env"] = try values.map { value -> [String: String] in
                try keys(value, allowed: ["name", "value"], owner: "exec.env")
                return ["name": try string(value["name"]), "value": try string(value["value"])]
            }
        }
        if let value = node["provideClusterInfo"] { result["provideClusterInfo"] = try boolean(value) }
        return result
    }
    private static func expiration(_ data: Data) -> Date? {
        var der = data
        if let pem = String(data: data, encoding: .utf8), let begin = pem.range(of: "-----BEGIN CERTIFICATE-----"),
           let end = pem.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<pem.endIndex) {
            guard let decoded = Data(base64Encoded: String(pem[begin.upperBound..<end.lowerBound]), options: .ignoreUnknownCharacters) else { return nil }
            der = decoded
        }
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any],
              let field = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any] else { return nil }
        if let date = field[kSecPropertyKeyValue as String] as? Date { return date }
        if let seconds = field[kSecPropertyKeyValue as String] as? NSNumber { return Date(timeIntervalSinceReferenceDate: seconds.doubleValue) }
        return nil
    }
}

private extension Node {
    /// Yams 的 `Tag.name` 不公开，用公开的 rawValue 还原。
    var tagName: Tag.Name { Tag.Name(rawValue: tag.rawValue) }
}
