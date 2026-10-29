import Foundation
import Models
import Testing
@testable import Storage

@Suite("项目")
struct ProjectRepositoryTests {
    @Test("重命名只改名称；项目不存在时报错")
    func rename() async throws {
        let database = try AppDatabase.inMemory()
        let project = try await database.createProject(Sample.project())
        let renamed = try await database.renameProject(project.id, to: "演示服务")
        #expect(renamed.name == "演示服务" && renamed.repositoryPath == project.repositoryPath)
        #expect(try await database.project(project.id)?.name == "演示服务")
        await #expect(throws: StorageError.notFound(entity: "项目", id: 999)) {
            try await database.renameProject(ProjectID(rawValue: 999), to: "x")
        }
    }
}
