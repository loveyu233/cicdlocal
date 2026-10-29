import Foundation
import Models
import Platform
import Testing
@testable import ApplicationKit

@Suite("kubeconfig 导入与 k8s 连接")
struct KubeconfigImportTests {
    func fixture(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "localcicd-kube-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    let yaml = """
    apiVersion: v1
    kind: Config
    current-context: selected
    contexts:
      - name: selected
        context: {cluster: local, user: selected-user, namespace: development}
      - name: other
        context: {cluster: other, user: other-user}
    clusters:
      - name: local
        cluster: {server: 'https://127.0.0.1:6443', certificate-authority: ca.pem}
      - name: other
        cluster: {server: 'https://unselected.invalid', certificate-authority: must-not-read}
    users:
      - name: selected-user
        user: {token: initial-token, tokenFile: token.txt, client-key: key.pem}
      - name: other-user
        user: {token: unselected-secret}
    """

    @Test("人工自签名客户端证书的有效期可解析，并提示 30 天内过期")
    func certificateExpiration() async throws {
        try await fixture { root in
            let result = try await CommandRunner().capture(Command(executable: "/usr/bin/openssl",
                arguments: ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                            "-subj", "/CN=localcicd-test.invalid",
                            "-keyout", root.appending(path: "key.pem").path,
                            "-out", root.appending(path: "cert.pem").path], timeout: .seconds(20)), limit: 8192)
            #expect(result.result.succeeded)
            let text = """
            apiVersion: v1
            kind: Config
            contexts: [{name: a, context: {cluster: a, user: a}}]
            clusters: [{name: a, cluster: {server: 'https://example.invalid'}}]
            users: [{name: a, user: {client-certificate: cert.pem, client-key: key.pem}}]
            """
            let url = root.appending(path: "config")
            try text.write(to: url, atomically: true, encoding: .utf8)
            let preview = try KubeconfigDocument.read(url).preview(context: "a")
            let expires = try #require(preview.certificateExpiresAt)
            #expect((86_300...86_500).contains(expires.timeIntervalSinceNow))
            #expect(preview.warnings.contains { $0.contains("30 天") })
            #expect(!String(reflecting: preview).contains("PRIVATE"))
        }
    }

    @Test("只导入所选 context 和引用文件；kubeconfig 存钥匙串，数据库只有名字和展示信息")
    func importConnection() async throws {
        try await fixture { root in
            let url = root.appending(path: "config")
            try yaml.write(to: url, atomically: true, encoding: .utf8)
            try Data("人工 CA".utf8).write(to: root.appending(path: "ca.pem"))
            try Data("人工私钥".utf8).write(to: root.appending(path: "key.pem"))
            try Data("selected-secret-token\n".utf8).write(to: root.appending(path: "token.txt"))
            let document = try KubeconfigDocument.read(url)
            #expect(document.contexts == ["other", "selected"])
            let preview = try document.preview(context: "selected")
            #expect(preview.server == "https://127.0.0.1:6443")
            #expect(preview.namespace == "development")
            #expect(preview.warnings.contains { $0.contains("回环") })
            #expect(!preview.warnings.joined().contains("selected-secret-token"))

            let secrets = InMemorySecretStore()
            let paths = AppPaths(applicationSupport: root.appending(path: "support"))
            let service = try ApplicationService(paths: paths, secrets: secrets)
            let connection = try await service.importConnection(name: "  测试环境 ", preview: preview)
            #expect(connection.name == "测试环境")
            #expect(connection.metadata.context == "selected")
            #expect(connection.metadata.server == "https://127.0.0.1:6443")
            #expect(connection.metadata.namespace == "development")
            #expect(connection.metadata.byteCount == preview.byteCount)

            let payload = try #require(try await secrets.value(account: connection.account))
            let text = String(decoding: payload, as: UTF8.self)
            #expect(text.contains("selected-secret-token"))
            #expect(!text.contains("unselected") && !text.contains("tokenFile") && !text.contains("key.pem"))
            let object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
            #expect((object["contexts"] as? [Any])?.count == 1)
            #expect((object["clusters"] as? [Any])?.count == 1)
            #expect((object["users"] as? [Any])?.count == 1)
            #expect(!text.contains(#"\/"#), "kubectl 的 YAML 解析器不认识 JSON 的斜杠转义")

            await #expect(throws: ApplicationError.self) { try await service.importConnection(name: "测试环境", preview: preview) }
            #expect(await secrets.accounts == [connection.account], "重名导入不能留下钥匙串条目")
            await #expect(throws: ApplicationError.self) { try await service.importConnection(name: "   ", preview: preview) }

            let renamed = try await service.renameConnection(connection.id, to: "正式环境")
            #expect(renamed.name == "正式环境")
            #expect(try await service.database.connection(named: "测试环境") == nil)

            await service.shutdown()
            for file in try FileManager.default.contentsOfDirectory(at: paths.applicationSupport, includingPropertiesForKeys: nil)
                where file.lastPathComponent.hasPrefix("localcicd.sqlite") {
                #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("selected-secret-token"))
            }
            try await service.deleteConnection(connection.id)
            #expect(await secrets.accounts.isEmpty)
            #expect(try await service.database.connections().isEmpty)
        }
    }

    static let kubectl = ["/opt/homebrew/bin/kubectl", "/usr/local/bin/kubectl"].first(where: FileManager.default.isExecutableFile)

    /// 用本机真实 kubectl 读取（config view 只解析文件，不连接集群），返回它看到的集群地址和 CA。
    func kubectlView(_ payload: Data, in root: URL) async throws -> (succeeded: Bool, output: String) {
        let url = root.appending(path: "kubeconfig-\(UUID().uuidString)")
        try payload.write(to: url)
        let result = try await CommandRunner().capture(Command(
            executable: try #require(Self.kubectl),
            arguments: ["config", "view", "--raw", "-o", "jsonpath={.clusters[0].cluster.server} {.clusters[0].cluster.certificate-authority-data}"],
            environment: ["KUBECONFIG": url.path], timeout: .seconds(20)), limit: 8192)
        return (result.result.succeeded, result.outputString + result.errorString)
    }

    @Test("导入保存的内容和早期版本带 \\/ 转义的内容，都能被真实 kubectl 读取", .enabled(if: kubectl != nil))
    func kubectlCanRead() async throws {
        try await fixture { root in
            let url = root.appending(path: "config")
            try """
            apiVersion: v1
            kind: Config
            contexts: [{name: a, context: {cluster: a}}]
            clusters: [{name: a, cluster: {server: 'https://k8s.example.invalid:6443', certificate-authority-data: YS9i+w==}}]
            """.write(to: url, atomically: true, encoding: .utf8)
            let payload = try KubeconfigDocument.read(url).preview(context: "a").payload
            let imported = try await kubectlView(payload, in: root)
            #expect(imported.succeeded && imported.output == "https://k8s.example.invalid:6443 YS9i+w==", "\(imported.output)")

            let old = Data(String(decoding: payload, as: UTF8.self).replacingOccurrences(of: "/", with: #"\/"#).utf8)
            #expect(try await !kubectlView(old, in: root).succeeded, "复现：kubectl 拒绝 \\/ 转义")
            let fixed = try await kubectlView(KubeconfigDocument.kubectlReadable(old), in: root)
            #expect(fixed.succeeded && fixed.output == "https://k8s.example.invalid:6443 YS9i+w==", "\(fixed.output)")
        }
    }

    @Test("exec 只保留配置并提示，不执行；不支持字段和畸形配置不得静默丢失")
    func validation() async throws {
        try await fixture { root in
            let base = """
            apiVersion: v1
            kind: Config
            contexts: [{name: a, context: {cluster: a, user: a}}]
            clusters: [{name: a, cluster: {server: 'https://example.invalid'}}]
            users: [{name: a, user: {exec: {command: '/must/not/execute', apiVersion: client.authentication.k8s.io/v1, args: [hello]}}}]
            """
            let url = root.appending(path: "config")
            try base.write(to: url, atomically: true, encoding: .utf8)
            let preview = try KubeconfigDocument.read(url).preview(context: "a")
            #expect(preview.warnings.contains { $0.contains("exec") })
            for invalid in [
                base.replacingOccurrences(of: "exec: {", with: "auth-provider: {"),
                base.replacingOccurrences(of: "https://example.invalid", with: "https://secret:password@example.invalid"),
                base.replacingOccurrences(of: "context: {cluster: a, user: a}", with: "context: {cluster: missing, user: a}"),
                base + "\nkind: Config\n",
                base + "\n---\npassword: never-echo-this\n",
                base + "\nextra: &a [*a]\n",
            ] {
                try invalid.write(to: url, atomically: true, encoding: .utf8)
                do {
                    _ = try KubeconfigDocument.read(url).preview(context: "a")
                    Issue.record("无效配置应被拒绝")
                } catch {
                    #expect(!String(describing: error).contains("never-echo-this"))
                    #expect(!String(describing: error).contains("secret:password"))
                }
            }
        }
    }
}
