import Foundation
import Testing
@testable import LogKit

@Suite("导入配置的凭据脱敏")
struct CredentialRedactionTests {
    @Test("Base64 或文件 kubeconfig 中的 token、私钥和插件值按跨块输出隐藏")
    func kubeconfig() throws {
        let key = "-----BEGIN PRIVATE KEY-----\n人工私钥正文\n-----END PRIVATE KEY-----"
        let config: [String: Any] = [
            "kind": "Config", "apiVersion": "v1",
            "users": [["name": "a", "user": ["token": "sample-token", "client-key-data": Data(key.utf8).base64EncodedString(),
                "exec": ["args": ["plugin-secret"], "env": [["name": "TOKEN", "value": "env-secret"]]]]]],
            "clusters": [["name": "a", "cluster": ["server": "https://example.invalid"]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        for secret in [String(decoding: data, as: UTF8.self), data.base64EncodedString()] {
            var sanitizer = try LogSanitizer(secrets: [secret])
            var output = ""
            for byte in Data("开始 sample-token 人工私钥正文 plugin-secret env-secret 结束".utf8) {
                output += sanitizer.append(Data([byte]))
            }
            output += sanitizer.finish()
            #expect(output == "开始 [已隐藏] [已隐藏] [已隐藏] [已隐藏] 结束")
        }
    }
}
