import Foundation
import GRDB
import Models

extension AppDatabase {
    /// 添加项目。`project.id` 应为 `.unsaved`；仓库路径重复时抛出约束错误。
    public func createProject(_ project: Project) async throws -> Project {
        try await writer.write { db in
            var project = project
            try project.insert(db)
            return project
        }
    }

    /// 删除项目及其推送记录、运行和阶段。磁盘上的日志由调用方清理。
    public func deleteProject(_ id: ProjectID) async throws {
        try await writer.write { db in
            guard try Project.deleteOne(db, key: id) else {
                throw StorageError.notFound(entity: "项目", id: id.rawValue)
            }
        }
    }

    public func project(_ id: ProjectID) async throws -> Project? {
        try await writer.read { db in try Project.fetchOne(db, key: id) }
    }

    public func projects() async throws -> [Project] {
        try await writer.read { db in try Self.projectsRequest.fetchAll(db) }
    }

    public func setHookMode(_ mode: HookMode, projectID: ProjectID) async throws {
        try await writer.write { db in
            guard var project = try Project.fetchOne(db, key: projectID) else {
                throw StorageError.notFound(entity: "项目", id: projectID.rawValue)
            }
            project.hookMode = mode
            try project.update(db)
        }
    }

    public func renameProject(_ id: ProjectID, to name: String) async throws -> Project {
        try await writer.write { db in
            guard var project = try Project.fetchOne(db, key: id) else {
                throw StorageError.notFound(entity: "项目", id: id.rawValue)
            }
            project.name = name
            try project.update(db)
            return project
        }
    }

    static var projectsRequest: QueryInterfaceRequest<Project> {
        Project.order(Column("name").collating(.localizedCaseInsensitiveCompare), Column("id"))
    }
}
