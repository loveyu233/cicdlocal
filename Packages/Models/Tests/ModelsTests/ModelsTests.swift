import Foundation
import Testing
@testable import Models

@Suite("本地 ID")
struct LocalIDTests {
    @Test("界面显示为 L-<数字>")
    func display() {
        #expect(RunID(18).display == "L-18")
        #expect("\(ProjectID(7))" == "L-7")
    }

    @Test("解析界面形式和纯数字，拒绝非法输入", arguments: [
        ("L-18", Int64?.some(18)),
        ("18", 18),
        ("L-0", nil),
        ("L--1", nil),
        ("#18", nil),
        ("", nil),
    ])
    func parse(text: String, expected: Int64?) {
        #expect(RunID(display: text)?.rawValue == expected)
    }

    @Test("编码为单个整数")
    func encodesAsInteger() throws {
        let data = try JSONEncoder().encode(RunID(42))
        #expect(String(decoding: data, as: UTF8.self) == "42")
    }
}

@Suite("提交 SHA")
struct CommitSHATests {
    @Test("接受 40 位和 64 位十六进制，统一为小写")
    func accepts() throws {
        let sha1 = try #require(CommitSHA(rawValue: String(repeating: "A", count: 40)))
        #expect(sha1.rawValue == String(repeating: "a", count: 40))
        #expect(CommitSHA(rawValue: String(repeating: "b", count: 64)) != nil)
        #expect(sha1.short == "aaaaaaaa")
    }

    @Test("拒绝长度或字符不对的值", arguments: [
        "", "abc", String(repeating: "g", count: 40), String(repeating: "a", count: 41),
        String(repeating: "０", count: 40),
    ])
    func rejects(text: String) {
        #expect(CommitSHA(rawValue: text) == nil)
    }

    @Test("解码非法 SHA 时报错")
    func decodeRejects() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CommitSHA.self, from: Data(#""xyz""#.utf8))
        }
    }

    @Test("全零 SHA")
    func zero() {
        #expect(CommitSHA.zero.isZero)
        #expect(Fixtures.sha1.isZero == false)
    }
}

@Suite("引用更新")
struct RefUpdateTests {
    @Test("按 SHA 判断新建、更新、删除；删除不触发运行")
    func kind() {
        var update = Fixtures.refUpdate
        #expect(update.kind == .update)
        update.oldSHA = .zero
        #expect(update.kind == .create)
        update.oldSHA = Fixtures.sha1
        update.newSHA = .zero
        #expect(update.kind == .delete)
        update.confirmation = .confirmed
        #expect(update.createsRun == false)
    }

    @Test("只有确认成功的分支推送可能触发运行，标签不触发")
    func createsRun() {
        var update = Fixtures.refUpdate
        for confirmation in RefUpdateConfirmation.allCases {
            update.confirmation = confirmation
            #expect(update.createsRun == (confirmation == .confirmed))
        }
        update.remoteRef = "refs/tags/v1.2"
        #expect(update.branch == nil)
        #expect(update.createsRun == false)
    }

    @Test("引用短名与分支名")
    func shortName() {
        var update = Fixtures.refUpdate
        #expect(update.shortRefName == "main")
        #expect(update.branch == "main")
        update.remoteRef = "refs/heads/feature/x"
        #expect(update.branch == "feature/x")
        update.remoteRef = "refs/tags/v1.2"
        #expect(update.shortRefName == "v1.2")
        #expect(update.isTag)
        update.remoteRef = "refs/for/main"
        #expect(update.shortRefName == "refs/for/main")
    }
}

@Suite("运行状态")
struct RunStatusTests {
    @Test("按阶段汇总：执行与等待优先，全部结束后汇总失败与取消")
    func settled() {
        #expect(RunStatus.settled([.succeeded, .running, .pending]) == nil)
        #expect(RunStatus.settled([.succeeded, .failed, .skipped]) == .failed)
        #expect(RunStatus.settled([.succeeded, .canceled, .skipped]) == .canceled)
        #expect(RunStatus.settled([.skipped, .succeeded, .waiting, .succeeded]) == .waiting)
        #expect(RunStatus.settled([.skipped, .succeeded, .expired, .succeeded]) == .succeeded)
        #expect(RunStatus.settled([.succeeded, .succeeded, .skipped]) == .succeeded)
    }

    @Test("等待确认不算结束")
    func finished() {
        #expect(!RunStatus.waiting.isFinished)
        #expect(RunStatus.interrupted.isFinished)
        #expect(!StageStatus.waiting.isFinished)
        #expect(StageStatus.expired.isFinished)
    }

    @Test("活跃任务优先显示运行中，空闲等待不被其他失败提前终结")
    func batchWaiting() {
        #expect(RunStatus.settled([.succeeded, .waiting, .pending]) == .waiting)
        #expect(RunStatus.settled([.succeeded, .running, .waiting]) == nil)
        #expect(RunStatus.settled([.failed, .waiting]) == .waiting)
        #expect(RunStatus.settled([.failed, .running]) == nil)
        #expect(RunStatus.settled([.failed, .pending]) == nil)
    }

    @Test("运行可以 JSON 往返")
    func codable() throws {
        let run = Run(id: .init(5), projectID: .init(1), refUpdateID: .init(3), branch: "main", commit: Fixtures.sha2,
                      image: "r.invalid/a:1", plan: "{}", status: .waiting, createdAt: Fixtures.date)
        #expect(try JSONDecoder().decode(Run.self, from: JSONEncoder().encode(run)) == run)
    }
}

@Suite("k8s 连接")
struct K8sConnectionTests {
    @Test("连接名去掉首尾空白，限制长度和控制字符")
    func names() {
        #expect(K8sConnection.normalizedName("  正式环境 ") == "正式环境")
        #expect(K8sConnection.normalizedName("   ") == nil)
        #expect(K8sConnection.normalizedName(String(repeating: "a", count: 65)) == nil)
        #expect(K8sConnection.normalizedName("a\u{7}b") == nil)
        #expect(K8sConnection.newAccount().hasPrefix("k8s/"))
        #expect(K8sConnection.newAccount() != K8sConnection.newAccount())
    }
}
