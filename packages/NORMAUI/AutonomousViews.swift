import SwiftUI
import ResearchContracts

struct ResearchStartSheet: View {
    @Bindable var model: AppModel
    let state: ResearchSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var calls = 40
    @State private var runs = 10
    @State private var knownProblem = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("开始自主研究").font(.title2)
            Text(state.contract.question)
            LabeledContent("模型", value: "GPT-6.1 Sol · 中等思考")
            Stepper("模型调用上限：\(calls) 次", value: $calls, in: 1...200)
            Stepper("实验运行上限：\(runs) 次", value: $runs, in: 2...40, step: 2)
            Toggle("验证已知问题，不要求创新性", isOn: $knownProblem)
            LabeledContent("实验范围", value: "本机 · 最多 5 条数据 · 不训练 · 每次 30 秒")
            Text("模型会读取已选研究资料。实验代码生成后需确认方案与设备，才会执行。")
            HStack {
                Button("取消") { dismiss() }; Spacer()
                Button("授权并开始") {
                    let command = AutonomousStart(id: state.id, revision: state.revision, maxModelCalls: calls, maxRuns: runs, knownProblem: knownProblem)
                    model.action { _ = try await model.client.call("autonomy.start", command, as: Empty.self) }
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(model.busy)
            }
        }.padding(28).frame(width: 620)
    }
}
struct AutonomousExecutionView: View {
    @Bindable var model: AppModel
    var body: some View {
        if let state = model.current, let proposal = state.autonomy?.pendingExperiment, let plan = state.plan {
            Panel("确认模型生成的实验") {
                Text(proposal.question).font(.headline)
                LabeledContent("输入数据", value: "\(proposal.data.array.count) 条")
                LabeledContent("评价指标", value: proposal.metric)
                DisclosureGroup("查看代码与输入") {
                    Text(proposal.python).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Text(String(decoding: (try? Codec.encode(proposal.data)) ?? Data(), as: UTF8.self)).textSelection(.enabled)
                }
                Button(state.confirmedPlanHash == plan.hash ? "方案已确认" : "确认实验方案") { model.command("plan.confirm") }
                    .disabled(state.confirmedPlanHash == plan.hash || state.operation.occupiesSlot || model.busy)
                HStack {
                    Button(state.selectedTargetID == "local" ? "已选择本机" : "选择本机") { model.selectLocal() }.disabled(state.confirmedPlanHash != plan.hash || state.operation.occupiesSlot || model.busy)
                    Button("检查运行条件") { model.command("target.preflight") }.disabled(state.selectedTargetID != "local" || state.operation.occupiesSlot || model.busy)
                    Spacer()
                    Button("执行并继续研究", systemImage: "play.fill") { model.command("autonomy.execute") }.buttonStyle(.borderedProminent)
                        .disabled(model.busy || state.operation != .waitingApproval || state.preflight?.passed != true || (state.preflight?.validUntil ?? .distantPast) <= Date())
                }
                if let report = state.preflight {
                    ForEach(report.checks) { check in HStack { Text(DisplayText.value(check.id)); Text(DisplayText.checkDetail(check)); Spacer(); StatusBadge(text: check.status.rawValue, status: check.status.rawValue) } }
                }
            }
        } else if let state = model.current { AutonomousProgressView(state: state) }
    }
}
struct AutonomousProgressView: View {
    let state: ResearchSnapshot
    private let stages = ["提出思路", "实验验证", "分析与改进", "撰写报告", "同行评审", "综合核查"]
    var body: some View {
        Panel("研究进度") {
            HStack { Text(DisplayText.value(state.phase.rawValue)); Spacer(); StatusBadge(text: state.operation.rawValue, status: state.operation.rawValue) }
            ProgressView(value: Double(state.phase == .finished ? (state.autonomy?.history.map { $0.phase.group }.max().map { $0 + 1 } ?? 0) : state.phase.group), total: 6)
            HStack { ForEach(stages, id: \.self) { Text($0).font(.caption).frame(maxWidth: .infinity) } }
            if let last = state.autonomy?.history.last { Text(last.proposal.summary).textSelection(.enabled) }
            if let error = state.lastError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let outcome = state.outcome { Text(DisplayText.value(outcome.rawValue)).fontWeight(.medium) }
        }
    }
}
