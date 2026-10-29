import Foundation
import Models
import Platform
import Runner

/// 子任务仍属于当前运行的结构化任务树，取消时同时结束构建、部署和唤醒等待。
private enum IndependentCompletion: Sendable {
    case build(RunStageID, Bool)
    case batch(String, Bool)
    case tick
}

extension ApplicationService {
    /// 部署只依赖自己的构建；重新替换的跳过项必须带有已核验的冻结摘要。
    static func batchReady(_ batch: LocalConfig.Batch, plan: RunPlan, stages: [RunStage]) -> Bool {
        batch.targets.allSatisfy { target in
            guard let image = plan.image(named: target.build), image.reference != nil else { return false }
            return stages.contains {
                $0.targetKey == image.stageKey && $0.kind == .build &&
                ($0.status == .succeeded || ($0.status == .skipped && $0.message == reusedImageMessage))
            }
        }
    }

    /// 仅在存在执行任务时短间隔检查持久化确认，避免长构建或健康观察阻塞用户点击。
    /// 空闲等待确认时退出调度器，释放项目队列；下一次确认由原项目队列重新唤醒。
    func scheduleIndependent(run: Run, project: Project, root: URL, shell: ShellEnvironment, warning: String?) async throws {
        try await withThrowingTaskGroup(of: IndependentCompletion.self) { group in
            var building: Set<RunStageID> = []
            var deploying: [String: Set<String>] = [:]
            var ticking = false
            while true {
                try Task.checkCancellation()
                guard let saved = try await database.run(run.id) else { throw ApplicationError("运行已不存在") }
                let plan = try decodePlan(saved)
                let stages = try await database.stages(runID: run.id)

                for stage in stages where stage.kind == .build && stage.status == .pending && !building.contains(stage.id) {
                    guard building.count < plan.parallel else { break }
                    building.insert(stage.id)
                    group.addTask {
                        let success = try await self.build(stage, plan: plan, run: run, root: root, shell: shell, warning: warning)
                        return .build(stage.id, success)
                    }
                }

                for batch in plan.batches where deploying[batch.name] == nil {
                    let keys = Set(batch.targets.map(\.stageKey))
                    let members = stages.filter { keys.contains($0.targetKey ?? "") }
                    guard members.count == batch.targets.count else { throw ApplicationError("部署批次阶段不完整") }
                    if members.allSatisfy({ $0.status.isFinished }) { continue }
                    let dependencies = Set(batch.targets.map(\.build))
                    let blocked = stages.contains { stage in
                        stage.kind == .build && plan.images.contains { dependencies.contains($0.name) && $0.stageKey == stage.targetKey } &&
                        (stage.status == .failed || stage.status == .canceled ||
                         (stage.status == .skipped && stage.message != Self.reusedImageMessage))
                    }
                    if blocked {
                        for member in members {
                            _ = try await database.transitionStage(member.id, from: [.pending], to: .skipped,
                                                                  message: "该批次依赖的镜像构建或核验未成功")
                        }
                        continue
                    }
                    guard Self.batchReady(batch, plan: plan, stages: stages) else { continue }
                    if batch.confirm && members.allSatisfy({ $0.status == .pending }) {
                        try await database.waitForBatch(run.id, ids: members.map(\.id), message: "等待确认批次「\(batch.name)」")
                        await notify(RunNotice(kind: .waiting, runID: run.id, projectName: project.name, branch: run.branch,
                                               message: "批次「\(batch.name)」镜像已就绪，可独立确认部署"))
                        continue
                    }
                    let executable = batch.confirm
                        ? members.allSatisfy { $0.status == .waiting && $0.message == Self.confirmedMessage }
                        : members.allSatisfy { $0.status == .pending }
                    guard executable else { continue }
                    let workloads = Set(batch.targets.map { "\($0.k8s)\n\($0.namespace)\n\($0.deployment)" })
                    // 不同服务可同时部署；同一 Deployment 的模板变更必须互斥。
                    guard deploying.values.allSatisfy({ $0.isDisjoint(with: workloads) }) else { continue }
                    deploying[batch.name] = workloads
                    group.addTask {
                        let success = try await self.runIndependentBatch(batch, members: members, plan: plan, run: run, root: root, shell: shell)
                        return .batch(batch.name, success)
                    }
                }

                if building.isEmpty && deploying.isEmpty {
                    group.cancelAll()
                    break
                }
                if !ticking {
                    ticking = true
                    group.addTask { try await Task.sleep(for: .milliseconds(100)); return .tick }
                }
                guard let completion = try await group.next() else { break }
                switch completion {
                case .tick: ticking = false
                case .build(let id, let success):
                    building.remove(id)
                    if !success { await notifyTaskFailure(run: run, project: project, ids: [id]) }
                case .batch(let name, let success):
                    deploying[name] = nil
                    if !success {
                        let ids = stages.filter { plan.batch(key: $0.targetKey)?.name == name }.map(\.id)
                        await notifyTaskFailure(run: run, project: project, ids: ids)
                    }
                }
            }
        }
        try Task.checkCancellation()
        let stages = try await database.stages(runID: run.id)
        let failures = stages.filter { $0.status == .failed }
        let message = failures.isEmpty ? nil : failures.map { "\($0.title)：\($0.message ?? "失败，详见日志")" }.joined(separator: "；")
            + "。其他批次独立处理，已成功替换的目标保留，未自动回滚"
        try await database.settle(run.id, message: message)
    }

    private func notifyTaskFailure(run: Run, project: Project, ids: [RunStageID]) async {
        let stages = (try? await database.stages(runID: run.id)) ?? []
        let details = stages.filter { ids.contains($0.id) && $0.status == .failed }
            .map { "\($0.title)：\($0.message ?? "失败，详见日志")" }.joined(separator: "；")
        await notify(RunNotice(kind: .failed, runID: run.id, projectName: project.name, branch: run.branch,
                               message: "\(details)。其他服务可继续"))
    }

    private func runIndependentBatch(_ batch: LocalConfig.Batch, members: [RunStage], plan: RunPlan,
                                     run: Run, root: URL, shell: ShellEnvironment) async throws -> Bool {
        let success = try await ConcurrentStages.run(members, limit: batch.parallel) { stage in
            guard let target = plan.target(key: stage.targetKey), let image = plan.image(named: target.build),
                  let reference = image.reference else { throw ApplicationError("部署目标缺少已核验的镜像") }
            let runner = StageRunner(root: root, shell: shell, variables: plan.variables.environment(image: reference, build: image.name))
            return try await self.deploy(stage, target: target, image: reference, run: run, runner: runner,
                                         from: [.pending, .waiting])?.succeeded == true
        }
        if !success {
            for member in members {
                _ = try await database.transitionStage(member.id, from: [.pending, .waiting], to: .skipped,
                                                      message: "同批次目标失败，本目标未启动；其他批次不受影响")
            }
        }
        return success
    }
}
