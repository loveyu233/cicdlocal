import Foundation

/// 识别导入器生成的 JSON kubeconfig，并登记其中单独打印也必须隐藏的凭据。
/// 不把任意 JSON 的普通字段或任意短字符串当作凭据扩展。
enum CredentialRedaction {
    static func expand(_ values: [String]) -> [String] {
        var result = values
        for value in values where value.utf8.count <= 65_536 {
            let original = Data(value.utf8)
            let data = value.first == "{" ? original : Data(base64Encoded: value)
            guard let data, data.count <= 65_536,
                  let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  config["kind"] as? String == "Config", config["apiVersion"] as? String == "v1",
                  let users = config["users"] as? [[String: Any]],
                  let clusters = config["clusters"] as? [[String: Any]] else { continue }
            result.append(String(decoding: data, as: UTF8.self))
            for item in users {
                guard let user = item["user"] as? [String: Any] else { continue }
                for key in ["token", "password", "client-key-data", "client-certificate-data"] {
                    if let secret = user[key] as? String {
                        result.append(secret)
                        if key.hasSuffix("-data"), let decoded = Data(base64Encoded: secret),
                           let text = String(data: decoded, encoding: .utf8) {
                            result.append(text)
                            result += text.split(whereSeparator: \.isNewline).map(String.init)
                        }
                    }
                }
                if let exec = user["exec"] as? [String: Any] {
                    // 插件参数和环境可能携带令牌，不猜测哪些参数是公开值。
                    result += exec["args"] as? [String] ?? []
                    result += (exec["env"] as? [[String: String]] ?? []).compactMap { $0["value"] }
                }
            }
            for item in clusters {
                if let cluster = item["cluster"] as? [String: Any], let proxy = cluster["proxy-url"] as? String {
                    result.append(proxy)
                    if let url = URLComponents(string: proxy), let password = url.password { result.append(password) }
                }
            }
        }
        return result
    }
}
