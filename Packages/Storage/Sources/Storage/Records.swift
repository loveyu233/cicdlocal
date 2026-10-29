import Foundation
import GRDB
import Models

// 实体与表行的映射。列名与 Schema.swift 一一对应，全部手写，
// 不依赖 Codable 的自动映射：属性改名时编译器会报错，而不是悄悄写出新列名。
//
// 约定：
// - `id` 为 `.unsaved` 时编码为 NULL，由数据库分配；插入后在 `didInsert` 中回填。
// - 读取时列值不合法（例如 SHA 不是 40 位十六进制）会抛出解码错误。

private func encodedID<Entity>(_ id: LocalID<Entity>) -> LocalID<Entity>? {
    id.isUnsaved ? nil : id
}

// MARK: project

extension Project: @retroactive TableRecord, @retroactive FetchableRecord, @retroactive EncodableRecord,
    @retroactive MutablePersistableRecord
{
    public static var databaseTableName: String { "project" }

    public init(row: Row) throws {
        self.init(
            id: try row.decode(forColumn: "id"),
            name: try row.decode(forColumn: "name"),
            repositoryPath: try row.decode(forColumn: "repository_path"),
            hookMode: try row.decode(forColumn: "hook_mode"),
            createdAt: try row.decode(forColumn: "created_at"))
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = encodedID(id)
        container["name"] = name
        container["repository_path"] = repositoryPath
        container["hook_mode"] = hookMode
        container["created_at"] = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = ProjectID(inserted.rowID)
    }
}

// MARK: push_event

extension PushEvent: @retroactive TableRecord, @retroactive FetchableRecord, @retroactive EncodableRecord,
    @retroactive MutablePersistableRecord
{
    public static var databaseTableName: String { "push_event" }

    public init(row: Row) throws {
        self.init(
            id: try row.decode(forColumn: "id"),
            projectID: try row.decode(forColumn: "project_id"),
            spoolEventID: try row.decode(forColumn: "spool_event_id"),
            remoteName: try row.decode(forColumn: "remote_name"),
            remoteURL: try row.decode(forColumn: "remote_url"),
            receivedAt: try row.decode(forColumn: "received_at"))
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = encodedID(id)
        container["project_id"] = projectID
        container["spool_event_id"] = spoolEventID
        container["remote_name"] = remoteName
        container["remote_url"] = remoteURL
        container["received_at"] = receivedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = PushEventID(inserted.rowID)
    }
}

// MARK: ref_update

extension RefUpdate: @retroactive TableRecord, @retroactive FetchableRecord, @retroactive EncodableRecord,
    @retroactive MutablePersistableRecord
{
    public static var databaseTableName: String { "ref_update" }

    public init(row: Row) throws {
        self.init(
            id: try row.decode(forColumn: "id"),
            pushEventID: try row.decode(forColumn: "push_event_id"),
            dedupKey: try row.decode(forColumn: "dedup_key"),
            remoteRef: try row.decode(forColumn: "remote_ref"),
            oldSHA: try row.decode(forColumn: "old_sha"),
            newSHA: try row.decode(forColumn: "new_sha"),
            isForced: try row.decode(forColumn: "is_forced"),
            confirmation: try row.decode(forColumn: "confirmation"),
            confirmedBy: try row.decode(forColumn: "confirmed_by"),
            confirmationReason: try row.decode(forColumn: "confirmation_reason"),
            resolvedCommitSHA: try row.decode(forColumn: "resolved_commit_sha"))
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = encodedID(id)
        container["push_event_id"] = pushEventID
        container["dedup_key"] = dedupKey
        container["remote_ref"] = remoteRef
        container["old_sha"] = oldSHA
        container["new_sha"] = newSHA
        container["is_forced"] = isForced
        container["confirmation"] = confirmation
        container["confirmed_by"] = confirmedBy
        container["confirmation_reason"] = confirmationReason
        container["resolved_commit_sha"] = resolvedCommitSHA
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = RefUpdateID(inserted.rowID)
    }
}

// MARK: run

extension Run: @retroactive TableRecord, @retroactive FetchableRecord, @retroactive EncodableRecord,
    @retroactive MutablePersistableRecord
{
    public static var databaseTableName: String { "run" }

    public init(row: Row) throws {
        self.init(
            id: try row.decode(forColumn: "id"),
            projectID: try row.decode(forColumn: "project_id"),
            refUpdateID: try row.decode(forColumn: "ref_update_id"),
            rerunOf: try row.decode(forColumn: "rerun_of"),
            branch: try row.decode(forColumn: "branch"),
            commit: try row.decode(forColumn: "sha"),
            commitMessage: try row.decode(forColumn: "commit_message"),
            image: try row.decode(forColumn: "image"),
            plan: try row.decode(forColumn: "plan_json"),
            status: try row.decode(forColumn: "status"),
            message: try row.decode(forColumn: "message"),
            createdAt: try row.decode(forColumn: "created_at"),
            startedAt: try row.decode(forColumn: "started_at"),
            finishedAt: try row.decode(forColumn: "finished_at"))
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = encodedID(id)
        container["project_id"] = projectID
        container["ref_update_id"] = refUpdateID
        container["rerun_of"] = rerunOf
        container["branch"] = branch
        container["sha"] = commit
        container["commit_message"] = commitMessage
        container["image"] = image
        container["plan_json"] = plan
        container["status"] = status
        container["message"] = message
        container["created_at"] = createdAt
        container["started_at"] = startedAt
        container["finished_at"] = finishedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = RunID(inserted.rowID)
    }
}

// MARK: run_stage

extension RunStage: @retroactive TableRecord, @retroactive FetchableRecord, @retroactive EncodableRecord,
    @retroactive MutablePersistableRecord
{
    public static var databaseTableName: String { "run_stage" }

    public init(row: Row) throws {
        self.init(
            id: try row.decode(forColumn: "id"),
            runID: try row.decode(forColumn: "run_id"),
            ordinal: try row.decode(forColumn: "ordinal"),
            kind: try row.decode(forColumn: "kind"),
            title: try row.decode(forColumn: "title"),
            targetKey: try row.decode(forColumn: "target_key"),
            status: try row.decode(forColumn: "status"),
            message: try row.decode(forColumn: "message"),
            startedAt: try row.decode(forColumn: "started_at"),
            finishedAt: try row.decode(forColumn: "finished_at"))
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = encodedID(id)
        container["run_id"] = runID
        container["ordinal"] = ordinal
        container["kind"] = kind
        container["title"] = title
        container["target_key"] = targetKey
        container["status"] = status
        container["message"] = message
        container["started_at"] = startedAt
        container["finished_at"] = finishedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = RunStageID(inserted.rowID)
    }
}

// MARK: k8s_connection

extension K8sConnection: @retroactive TableRecord, @retroactive FetchableRecord, @retroactive EncodableRecord,
    @retroactive MutablePersistableRecord
{
    public static var databaseTableName: String { "k8s_connection" }

    public init(row: Row) throws {
        self.init(
            id: try row.decode(forColumn: "id"),
            name: try row.decode(forColumn: "name"),
            account: try row.decode(forColumn: "account"),
            metadata: try JSONColumn.decode(KubeconfigMetadata.self, from: row.decode(forColumn: "metadata_json")),
            createdAt: try row.decode(forColumn: "created_at"))
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = encodedID(id)
        container["name"] = name
        container["account"] = account
        container["metadata_json"] = try JSONColumn.encode(metadata)
        container["created_at"] = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = K8sConnectionID(inserted.rowID)
    }
}
