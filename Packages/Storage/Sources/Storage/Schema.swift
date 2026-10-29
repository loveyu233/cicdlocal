import GRDB

/// 版本化迁移。
///
/// 规则：
/// - 已发布的迁移**不再修改**，只追加新的迁移；
/// - 表名、列名用 snake_case，与 Models 的属性一一对应；
/// - 外键全部显式声明删除行为：属于项目的数据随项目删除，引用关系断开时置空。
public enum Schema {
    /// 当前的全部迁移标识，按顺序。测试按它逐个版本验证。
    public static var migrationIdentifiers: [String] { migrator.migrations }

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1", migrate: v1)
        migrator.registerMigration("v2", migrate: v2)
        return migrator
    }

    static func v1(_ db: Database) throws {
        try db.create(table: "project") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull()
            t.column("repository_path", .text).notNull().unique()
            t.column("hook_mode", .text).notNull()
            t.column("created_at", .datetime).notNull()
        }

        try db.create(table: "push_event") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("project_id", .integer).notNull().indexed()
                .references("project", onDelete: .cascade)
            // 钩子写入 spool 的事件 ID。重复投递时按它去重。
            t.column("spool_event_id", .text).notNull().unique()
            t.column("remote_name", .text).notNull()
            t.column("remote_url", .text).notNull()
            t.column("received_at", .datetime).notNull()
        }

        try db.create(table: "ref_update") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("push_event_id", .integer).notNull().indexed()
                .references("push_event", onDelete: .cascade)
            t.column("dedup_key", .text).notNull().unique()
            t.column("remote_ref", .text).notNull()
            t.column("old_sha", .text).notNull()
            t.column("new_sha", .text).notNull()
            t.column("is_forced", .boolean).notNull().defaults(to: false)
            t.column("confirmation", .text).notNull()
            t.column("confirmed_by", .text)
            t.column("confirmation_reason", .text)
            t.column("resolved_commit_sha", .text)
        }

        try db.create(table: "run") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("project_id", .integer).notNull()
                .references("project", onDelete: .cascade)
            // 一次推送的一个引用最多触发一次运行。
            t.column("ref_update_id", .integer).unique()
                .references("ref_update", onDelete: .setNull)
            t.column("rerun_of", .integer).references("run", onDelete: .setNull)
            t.column("branch", .text).notNull()
            t.column("sha", .text).notNull()
            t.column("image", .text)
            t.column("plan_json", .text)
            t.column("status", .text).notNull().indexed()
            t.column("message", .text)
            t.column("created_at", .datetime).notNull()
            t.column("started_at", .datetime)
            t.column("finished_at", .datetime)
        }
        try db.create(index: "run_on_project", on: "run", columns: ["project_id", "id"])

        try db.create(table: "run_stage") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("run_id", .integer).notNull()
                .references("run", onDelete: .cascade)
            t.column("ordinal", .integer).notNull().check { $0 >= 0 }
            t.column("kind", .text).notNull()
            t.column("title", .text).notNull()
            t.column("target_key", .text)
            t.column("status", .text).notNull()
            t.column("message", .text)
            t.column("started_at", .datetime)
            t.column("finished_at", .datetime)
            t.uniqueKey(["run_id", "ordinal"])
        }
        try db.create(index: "run_stage_waiting", on: "run_stage", columns: ["status", "target_key"])

        // 推送的处理结果：创建了哪个运行，或者为什么没有运行。同一个引用更新只处理一次。
        try db.create(table: "push_dispatch") { t in
            t.column("ref_update_id", .integer).primaryKey().references("ref_update", onDelete: .cascade)
            t.column("run_id", .integer).references("run", onDelete: .setNull)
            t.column("message", .text).notNull()
            t.column("created_at", .datetime).notNull()
        }

        // kubeconfig 只在钥匙串里；这里只有名字、钥匙串 account 和展示用的非凭据信息。
        try db.create(table: "k8s_connection") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().unique()
            t.column("account", .text).notNull().unique()
            t.column("metadata_json", .text).notNull()
            t.column("created_at", .datetime).notNull()
        }
    }

    /// 运行记下提交说明。
    static func v2(_ db: Database) throws {
        try db.alter(table: "run") { t in
            t.add(column: "commit_message", .text)
        }
    }
}
