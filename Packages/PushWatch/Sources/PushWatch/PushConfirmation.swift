import CryptoKit
import Darwin
import Foundation
import GitKit
import HookProtocol
import Models
import Storage

public struct ConfirmedPush: Sendable {
    public var event: PushEvent
    public var updates: [RefUpdate]
}

/// 只核实已经由本机 Git 记录的事件，不通过远端变化发现新任务。
public struct PushConfirmation: Sendable {
    public let database: AppDatabase
    public init(database: AppDatabase) { self.database = database }

    public func scan(_ installed: InstalledHooks) async throws -> [ConfirmedPush] {
        let installation = installed.installation
        let spool = try HookSpool(root: URL(fileURLWithPath: installation.spoolPath))
        let receiptNames = try spool.names(suffix: ".receipt.json")
        var receipts: [UUID: [HookReceipt]] = [:]
        for name in receiptNames {
            let receipt = try spool.read(HookReceipt.self, name: name)
            receipts[receipt.intentID, default: []].append(receipt)
        }
        var results: [ConfirmedPush] = []
        for name in try spool.names(suffix: ".intent.json") {
            let intent = try spool.read(HookIntent.self, name: name)
            guard intent.installationID == installation.id, intent.projectID == installation.projectID,
                intent.repositoryPath == installation.repositoryPath, intent.id.uuidString + ".intent.json" == name
            else { continue }
            let event = PushEvent(
                id: .unsaved, projectID: ProjectID(installation.projectID), spoolEventID: intent.id.uuidString,
                remoteName: intent.remoteName, remoteURL: intent.remoteURL, receivedAt: intent.receivedAt)
            let updates = try intent.refs.map { ref -> RefUpdate in
                guard HookRef.validRef(ref.remoteRef), let old = CommitSHA(rawValue: ref.oldSHA),
                    let new = CommitSHA(rawValue: ref.newSHA)
                else { throw HookFailure("推送意图中的引用或提交不合法") }
                return RefUpdate(id: .unsaved, pushEventID: .unsaved, dedupKey: "", remoteRef: ref.remoteRef, oldSHA: old, newSHA: new)
            }
            let stored: PushEvent
            switch try await database.recordPushEvent(event, refUpdates: updates) {
            case .recorded(let recorded, _), .duplicate(let recorded): stored = recorded
            }
            for update in try await database.refUpdates(pushEventID: stored.id) {
                if [.confirmed, .rejected].contains(update.confirmation) { continue }
                let proved = receipts[intent.id, default: []].contains { receipt in
                    receipt.process == intent.process && receipt.recordedAt >= intent.receivedAt &&
                    receipt.updates.contains { $0.remoteRef == update.remoteRef && $0.newSHA == update.newSHA.rawValue }
                }
                if proved {
                    _ = try await database.confirmRefUpdate(update.id, confirmation: .confirmed, by: .referenceTransaction,
                        reason: "本次 Git 推送进程已提交对应远端跟踪引用的更新")
                } else if intent.permitsExitConfirmation == true,
                    let exit = try? spool.read(PushExitReceipt.self, name: "\(intent.process.key).exit.json"),
                    exit.process == intent.process, exit.succeeded, exit.recordedAt >= intent.receivedAt {
                    let check = try await remoteCheck(intent: intent, update: update, spool: spool)
                    _ = try await database.confirmRefUpdate(update.id, confirmation: check.matches ? .confirmed : .unconfirmable,
                        by: check.matches ? .lsRemote : nil, reason: check.message)
                } else if !intent.process.isRunning {
                    _ = try await database.confirmRefUpdate(update.id, confirmation: .unconfirmable, by: nil,
                        reason: "未取得本次推送的成功证据；可能推送失败、使用了 dry-run，或该引用没有远端跟踪映射")
                }
            }
            results.append(ConfirmedPush(event: stored, updates: try await database.refUpdates(pushEventID: stored.id)))
        }
        return results
    }

    /// 确定结果与分发记录全部落库后归档，保留原始证据供诊断。不能归档仍可能补证的事件。
    public func archiveCompleted(_ record: ConfirmedPush, installed: InstalledHooks) async throws {
        guard record.updates.allSatisfy({ [.confirmed, .rejected].contains($0.confirmation) }) else { return }
        for update in record.updates where update.createsRun {
            guard try await database.pushDispatch(update.id) != nil else { return }
        }
        let spool = try HookSpool(root: URL(fileURLWithPath: installed.installation.spoolPath))
        let intent = try spool.read(HookIntent.self, name: "\(record.event.spoolEventID).intent.json")
        guard intent.installationID == installed.installation.id, !intent.process.isRunning else { return }
        let archive = try HookSpool(root: spool.root.appendingPathComponent("archive", isDirectory: true))
        for name in try spool.names(suffix: ".json") where name.hasPrefix("\(intent.id.uuidString).") {
            guard rename(spool.root.appendingPathComponent(name).path, archive.root.appendingPathComponent(name).path) == 0 else {
                throw HookFailure("无法归档已处理的推送记录")
            }
        }
        let activeName = "\(intent.process.key).active.json"
        if let active = try? spool.read(HookIntent.self, name: activeName), active.id == intent.id {
            _ = unlink(spool.root.appendingPathComponent(activeName).path)
        }
    }

    private func remoteCheck(intent: HookIntent, update: RefUpdate, spool: HookSpool) async throws -> RemoteCheck {
        let name = "\(intent.id.uuidString).\(update.id.rawValue).remote-check.json"
        if let saved = try? spool.read(RemoteCheck.self, name: name),
            saved.intentID == intent.id, saved.remoteRef == update.remoteRef, saved.newSHA == update.newSHA.rawValue { return saved }
        var check = RemoteCheck(intentID: intent.id, remoteRef: update.remoteRef, newSHA: update.newSHA.rawValue,
            matches: false, message: "远端核实曾中断，未取得确定结果")
        try spool.write(check, name: name)
        do {
            let repository = try await GitRepository.open(URL(fileURLWithPath: intent.repositoryPath))
            let url: String
            if intent.remoteName == intent.remoteURL {
                url = intent.remoteURL
            } else {
                url = try await repository.pushURL(remote: intent.remoteName)
                let fingerprint = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
                guard fingerprint == intent.remoteFingerprint else { throw HookFailure("远端推送地址已变化") }
            }
            let actual = try await repository.remoteObject(url: url, targetRef: update.remoteRef)
            check.matches = update.newSHA.isZero ? actual == nil : actual == update.newSHA
            check.message = check.matches
                ? "本次非 dry-run 的 Git 推送成功退出，且远端准确引用与本次更新一致"
                : "Git 已成功退出，但远端引用已变化或无法对应本次提交；未猜测推送结果"
        } catch { check.message = "Git 已成功退出，但远端地址已变化或引用无法读取" }
        // 无论网络失败还是远端已前进都保留首轮核实结果，不反复轮询远端等它“碰巧相等”。
        try spool.write(check, name: name)
        return check
    }
}

private struct RemoteCheck: Codable, Sendable {
    var intentID: UUID
    var remoteRef: String
    var newSHA: String
    var matches: Bool
    var message: String
}
