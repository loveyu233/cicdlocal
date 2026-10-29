import ApplicationKit
import Models
import Runner
import Storage
import SwiftUI

/// 右栏：一次运行的三个阶段和所选阶段的日志；需要确认的替换阶段在日志位置显示确认面板。
struct RunDetailView: View {
    let runID: RunID
    let project: Project
    let service: ApplicationService
    @Environment(AppModel.self) private var model
    @State private var run: Run?
    @State private var plan: RunPlan?
    @State private var stages: [RunStage] = []
    @State private var loaded = false
    @State private var selectedStage: RunStageID?
    @State private var pendingConfirm: RunStage?
    @State private var confirmingRedeploy = false
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if let run {
                content(run)
            } else if loaded {
                ContentUnavailableView("运行已不存在", systemImage: "questionmark.circle")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(project.name)
        .navigationSubtitle(run.map { "\($0.branch) · \($0.commit.short)" } ?? "")
        .toolbar { if let run { toolbar(run) } }
        .onChange(of: model.stageRequestID, initial: true) { _, _ in
            if let stage = model.requestedStage { selectedStage = stage }
        }
        .task {
            do {
                for try await run in service.database.observeRun(runID) {
                    if let json = run?.plan {
                        plan = try? JSONDecoder().decode(RunPlan.self, from: Data(json.utf8))
                    }
                    withAnimation(.snappy) { self.run = run }
                    loaded = true
                }
            } catch { model.errorMessage = "读取运行失败：\(error)" }
        }
        .task {
            do {
                for try await stages in service.database.observeStages(runID: runID) {
                    withAnimation(.snappy) { self.stages = stages }
                }
            } catch { model.errorMessage = "读取阶段失败：\(error)" }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { pendingConfirm != nil }, set: { if !$0 { pendingConfirm = nil } }),
                            presenting: pendingConfirm) { stage in
            Button("确认替换") { confirm(stage) }
            Button("取消", role: .cancel) {}
        } message: { stage in
            Text(batchDescription(for: stage))
        }
        .confirmationDialog("重新替换这组镜像？", isPresented: $confirmingRedeploy) {
            Button("重新替换") { redeploy() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(redeployMessage)
        }
        .confirmationDialog("删除这次运行？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) { delete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("运行记录和日志一并删除，不影响已推送的镜像和集群。")
        }
    }

    // MARK: - 内容

    private func content(_ run: Run) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header(run)
                if !stages.isEmpty { stageStrip }
            }
            .padding(20)
            Divider()
            if let stage = currentStage, isAwaitingConfirm(stage) {
                // 等待确认的阶段还没有日志：确认放在日志的位置，确认后这里换成 kubectl 的输出。
                confirmPanel(stage)
                    .id(stage.id)
            } else if let stage = currentStage, stage.status == .waiting, plan == nil {
                ContentUnavailableView("历史运行计划", systemImage: "clock.arrow.circlepath",
                                       description: Text("旧计划仅供查看。请提交新版 .local.cicd.yml 后创建运行。"))
            } else if let stage = currentStage {
                StageLogView(stage: stage, service: service)
                    .id(stage.id)
            } else {
                ContentUnavailableView("没有执行任何阶段", systemImage: "list.bullet.rectangle",
                                       description: Text(run.message ?? "运行在开始前就结束了。"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ run: Run) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusSymbol(run.status)
                Text(run.status.title)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("run-status")
                Spacer()
                if run.status == .running || run.finishedAt != nil {
                    ElapsedText(start: run.startedAt, end: run.finishedAt)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.title2)
            if let message = run.message {
                // 替换失败的完整原因在阶段日志上方，这里只留开头。
                Text(message)
                    .foregroundStyle(run.status == .failed || run.status == .interrupted ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .help(message)
            }
            if let commitMessage = run.commitMessage, !commitMessage.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "text.bubble").foregroundStyle(.secondary)
                    Text(commitMessage)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .help(commitMessage)
                        .accessibilityIdentifier("commit-message")
                }
            }
            if let image = selectedImage?.image ?? run.image {
                HStack(spacing: 6) {
                    Image(systemName: "shippingbox").foregroundStyle(.secondary)
                    Text(image)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(selectedImage?.reference.map { "\(image)\n部署锁定：\($0)" } ?? image)
                    Button("复制镜像地址", systemImage: "doc.on.doc") { copyToPasteboard(image) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("复制镜像地址")
                }
            }
        }
    }

    /// 替换目标多、窗口窄时换到下一行，不横向裁掉。
    private var stageStrip: some View {
        StageStrip {
            ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                HStack(spacing: 6) {
                    if index > 0 {
                        Image(systemName: "chevron.forward")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    StageChip(stage: stage, label: chipLabel(stage), selected: stage.id == currentStage?.id) {
                        selectedStage = stage.id
                    }
                }
            }
        }
        .padding(.vertical, 2)
        // 作为容器，否则标识会覆盖到每个阶段按钮上。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stage-strip")
    }

    private func confirmPanel(_ stage: RunStage) -> some View {
        let target = target(of: stage)
        return ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse, options: .repeating)
                VStack(spacing: 4) {
                    Text("等待确认批次「\(target?.batch ?? "")」")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("确认将执行下列全部目标。此批次的镜像已就绪，可独立部署，无需等待其他构建或批次。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                    // 例如重启后「上次确认未执行，请重新确认」。
                    if let message = stage.message, !message.hasPrefix("等待确认") {
                        Text(message).foregroundStyle(.orange)
                    }
                }
                if let batch = plan?.batch(key: stage.targetKey) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        confirmRow("环境", batch.k8s)
                        confirmRow("并发上限", String(batch.parallel))
                        ForEach(batch.targets, id: \.stageKey) { member in
                            confirmRow(member.build, "\(member.namespace) / \(member.deployment) / \(member.container)")
                            confirmRow("镜像", plan?.image(named: member.build)?.reference ?? "尚未核验")
                        }
                    }
                    .textSelection(.enabled)
                    .padding(14)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 12))
                }
                HStack(spacing: 12) {
                    Button("跳过批次") {
                        model.perform("skip-\(stage.id)") { try await $0.skip(stage.id, runID: runID) }
                    }
                    .controlSize(.large)
                    .disabled(model.isBusy("skip-\(stage.id)"))
                    Button("确认批次 \(target?.batch ?? "")") { pendingConfirm = stage }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(model.isBusy("confirm-\(stage.id)"))
                        .accessibilityIdentifier("confirm-deploy")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
    }

    private func confirmRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ run: Run) -> some ToolbarContent {
        ToolbarItemGroup {
            if !run.status.isFinished {
                Button("取消运行", systemImage: "stop.fill") {
                    model.perform("cancel-\(runID)") { try await $0.cancel(runID) }
                }
                .help("取消运行，正在执行的命令会被终止")
            }
            if ApplicationService.canRedeploy(run, stages: stages) {
                Button("重新替换", systemImage: "arrow.uturn.backward") { confirmingRedeploy = true }
                    .help("把这次的镜像重新替换到集群，不重新测试和构建，可用于回滚")
                    .disabled(model.isBusy("redeploy-\(runID)"))
                    .accessibilityIdentifier("redeploy-run")
            }
            if run.status.isFinished || run.status == .waiting {
                Button("重新运行", systemImage: "arrow.clockwise") {
                    model.perform("rerun-\(runID)") { service in
                        if let id = try await service.rerun(runID) { model.detail = .run(id) }
                    }
                }
                .help("按同一个提交重新读取配置并运行")
                .disabled(model.isBusy("rerun-\(runID)"))
                Button("删除运行", systemImage: "trash") { confirmingDelete = true }
                    .help("删除这次运行的记录和日志")
                    .disabled(model.isBusy("delete-\(runID)"))
                    .accessibilityIdentifier("delete-run")
            }
        }
    }

    // MARK: - 辅助

    /// 未手动选择时，显示正在进行、等待或失败的阶段，否则显示最后一个执行过的阶段。
    private var currentStage: RunStage? {
        if let selectedStage, let stage = stages.first(where: { $0.id == selectedStage }) { return stage }
        return stages.first { [.running, .waiting, .failed].contains($0.status) }
            ?? stages.last { ![.pending, .skipped].contains($0.status) }
            ?? stages.first
    }

    private func isAwaitingConfirm(_ stage: RunStage) -> Bool {
        stage.status == .waiting && stage.message != ApplicationService.confirmedMessage && plan != nil
    }

    private func target(of stage: RunStage) -> LocalConfig.Target? {
        plan?.target(key: stage.targetKey)
    }

    /// 标签用于顶部展示和复制，冻结摘要继续用于实际部署与确认。
    private var selectedImage: RunPlan.Image? {
        guard let plan, let stage = currentStage else { return nil }
        return plan.images.first { $0.stageKey == stage.targetKey }
            ?? target(of: stage).flatMap { plan.image(named: $0.build) }
    }

    private func chipLabel(_ stage: RunStage) -> String { stage.title }

    private var confirmTitle: String {
        pendingConfirm.flatMap { plan?.batch(key: $0.targetKey) }.map { "确认批次「\($0.name)」的全部目标？" } ?? "确认替换？"
    }

    private func batchDescription(for stage: RunStage) -> String {
        guard let batch = plan?.batch(key: stage.targetKey) else { return "此历史记录不支持新版批次操作" }
        return (["环境：\(batch.k8s)，并发上限：\(batch.parallel)"] + batch.targets.map { target in
            "\(target.build)：\(target.namespace) / \(target.deployment) / \(target.container)\n镜像：\(plan?.image(named: target.build)?.reference ?? "尚未核验")"
        }).joined(separator: "\n")
    }

    private var redeployMessage: String {
        plan?.batches.map { batch in
            "\(batch.name) · \(batch.k8s)（\(batch.confirm ? "需确认" : "自动")）\n" + batch.targets.map {
                "\($0.namespace)/\($0.deployment)/\($0.container)：\(plan?.image(named: $0.build)?.reference ?? "尚未核验")"
            }.joined(separator: "\n")
        }.joined(separator: "\n") ?? "历史计划不能按新版语义重新替换"
    }

    private func redeploy() {
        model.perform("redeploy-\(runID)") { service in
            if let id = try await service.redeploy(runID) { model.detail = .run(id) }
        }
    }

    private func delete() {
        model.perform("delete-\(runID)") { service in
            try await service.deleteRun(runID)
            if model.detail == .run(runID) { model.detail = .overview }
        }
    }

    private func confirm(_ stage: RunStage) {
        model.perform("confirm-\(stage.id)") { try await $0.confirm(stage.id, runID: runID) }
    }
}

private struct StageChip: View {
    let stage: RunStage
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                StatusSymbol(stage)
                Text(label).lineLimit(1)
                if stage.startedAt != nil {
                    ElapsedText(start: stage.startedAt, end: stage.finishedAt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.fill.quaternary), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(stage.message.map { "\(stage.title)：\($0)" } ?? "\(stage.title)：\(stage.status.title)")
        .accessibilityIdentifier("stage-\(stage.ordinal)")
        .accessibilityValue(stage.status.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension StatusSymbol {
    init(_ stage: RunStage) {
        // 已确认、排队等待替换的阶段不再跳动。
        let queued = stage.status == .waiting && stage.message == ApplicationService.confirmedMessage
        self.init(symbol: queued ? "clock" : stage.status.symbol, tint: queued ? .secondary : stage.status.tint,
                  active: stage.status == .running, waiting: stage.status == .waiting && !queued)
    }
}
