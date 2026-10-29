import Foundation

/// 每个运行开始时固定一次的变量。只替换这三个，其他 `${X}` 原样交给 shell。
public struct RunVariables: Sendable, Equatable, Codable {
    public static let names = ["TIME", "SHA", "BRANCH"]

    /// 北京时间 yyyyMMdd.HHmmss。
    public var time: String
    /// 12 位短提交号。
    public var sha: String
    /// 分支名，`[A-Za-z0-9_.-]` 以外的字符替换成 `-`，可直接用在镜像标签里。
    public var branch: String

    public init(date: Date = Date(), commit: String, branch: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        time = String(format: "%04d%02d%02d.%02d%02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        sha = String(commit.lowercased().prefix(12))
        self.branch = String(String.UnicodeScalarView(branch.unicodeScalars.map {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0)) ? $0 : "-"
        }))
    }

    public func expand(_ text: String) -> String {
        text.replacingOccurrences(of: "${TIME}", with: time)
            .replacingOccurrences(of: "${SHA}", with: sha)
            .replacingOccurrences(of: "${BRANCH}", with: branch)
    }

    /// 每条命令都能读取的环境变量。
    public func environment(image: String? = nil, build: String? = nil) -> [String: String] {
        var values = ["CICD_TIME": time, "CICD_SHA": sha, "CICD_BRANCH": branch]
        values["CICD_IMAGE"] = image
        values["CICD_BUILD"] = build
        return values
    }
}

/// 冻结的新版计划；旧计划不隐式转换成新批次语义，历史记录仍可查看。
public struct RunPlan: Sendable, Equatable, Codable {
    public enum Build: Sendable, Equatable, Codable {
        case dockerfile(path: String, platform: String?)
        case command(String)
    }
    public struct Image: Sendable, Equatable, Codable {
        public var name: String
        public var image: String
        public var build: Build
        public var digest: String?
        public init(name: String, image: String, build: Build, digest: String? = nil) {
            self.name = name; self.image = image; self.build = build; self.digest = digest
        }
        public var stageKey: String { "build\n\(name)" }
        public var reference: String? {
            guard let digest else { return nil }
            let tagged = image.split(separator: "@", maxSplits: 1).first.map(String.init) ?? image
            let slash = tagged.lastIndex(of: "/")
            let repository: String
            if let colon = tagged.lastIndex(of: ":"), slash == nil || colon > slash! { repository = String(tagged[..<colon]) }
            else { repository = tagged }
            return repository + "@" + digest
        }
    }
    public var version = 2
    public var variables: RunVariables
    public var tests: [String]
    public var parallel: Int
    public var images: [Image]
    public var batches: [LocalConfig.Batch]
    public var targets: [LocalConfig.Target] { batches.flatMap(\.targets) }
    public var environment: [String: String] { variables.environment() }
    public var summary: String { images.map { $0.image }.joined(separator: "、") }
    public var isDeployable: Bool { !images.isEmpty && images.allSatisfy { $0.reference != nil } }

    public func image(named name: String) -> Image? { images.first { $0.name == name } }
    public func target(key: String?) -> LocalConfig.Target? { targets.first { $0.stageKey == key } }
    public func batch(key: String?) -> LocalConfig.Batch? { batches.first { $0.targets.contains { $0.stageKey == key } } }
}

extension LocalConfig {
    public func plan(branch: String, variables: RunVariables) -> RunPlan? {
        let batches = deploy.filter { $0.branches.contains(branch) }
        guard !batches.isEmpty else { return nil }
        let names = Set(batches.flatMap(\.targets).map(\.build))
        let images = build.images.filter { names.contains($0.name) }.map { item in
            let step: RunPlan.Build = if let path = item.dockerfile {
                .dockerfile(path: path, platform: item.platform)
            } else { .command(variables.expand(item.command ?? "")) }
            return RunPlan.Image(name: item.name, image: variables.expand(item.image), build: step)
        }
        return RunPlan(variables: variables, tests: test.map(variables.expand), parallel: build.parallel, images: images, batches: batches)
    }
}
