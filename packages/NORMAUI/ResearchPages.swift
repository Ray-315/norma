import SwiftUI
import Charts
import ResearchContracts
struct OverviewView: View {
    @Environment(ThemeManager.self) private var theme
    @Bindable var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            metric("活跃课题", model.researches.filter { $0.phase != .finished && $0.operation != .cancelled }.count, "/ 4")
            metric("运行中实验", model.researches.flatMap(\.runs).filter { $0.state == .running }.count, "")
            metric("待授权", model.researches.filter { $0.operation == .waitingApproval }.count, "")
            metric("模型调用", model.researches.reduce(0) { $0 + $1.modelCalls }, "")
        }
        Panel("ScientistTwo Pipeline") { Pipeline(current: model.current?.phase.group ?? 0) }
        Panel("研究课题") {
            ForEach(model.researches) { state in
                Button { model.selectedID = state.id; model.page = .workspace } label: {
                    HStack { VStack(alignment: .leading, spacing: 7) { Text(state.contract.title).fontWeight(.medium); Text(state.contract.question).foregroundStyle(.secondary).lineLimit(2) }; Spacer(); StatusBadge(text: state.operation.rawValue, status: state.operation.rawValue) }.padding(.vertical, 7)
                }.buttonStyle(.plain)
                Divider()
            }
            if model.researches.isEmpty { Text("—").foregroundStyle(.secondary) }
        }
        Panel("Recent Activity") {
            ForEach(Array((model.current?.events ?? []).reversed().prefix(8))) { event in
                HStack(alignment: .top) { Circle().fill(theme.accent).frame(width: 5, height: 5).padding(.top, 5); Text(event.kind); Spacer(); Text(event.date, style: .time).foregroundStyle(.secondary) }
            }
        }.font(.system(size: 11))
    }
    private func metric(_ title: String, _ count: Int, _ suffix: String) -> some View {
        Panel(title) { HStack(alignment: .firstTextBaseline, spacing: 5) { Text(String(count)).font(.system(size: 27, weight: .semibold)); Text(suffix).foregroundStyle(.secondary) } }
    }
}
struct WorkspaceView: View {
    @Bindable var model: AppModel
    @State private var showContract = false
    var body: some View {
        if let state = model.current {
            Panel("Research Contract · v" + String(state.contract.version)) {
                Text(state.contract.question).font(.system(size: 17, weight: .medium))
                LabeledContent("主指标", value: state.contract.metric)
                if !state.contract.constraints.isEmpty { Text(state.contract.constraints).foregroundStyle(.secondary) }
                HStack {
                    Button("新建合同版本") { showContract = true }.disabled(state.operation.occupiesSlot)
                    Button("Pause", systemImage: "pause") { model.command("research.pause") }.disabled(state.operation.occupiesSlot)
                    Button("Resume", systemImage: "play") { model.command("research.resume") }.disabled(state.operation != .paused)
                    Button("Cancel", systemImage: "stop") { model.command("research.cancel") }.disabled(state.operation == .cancelled)
                    if state.operation == .unknown { Button("核对执行结果") { model.command("research.reconcile") } }
                    Spacer()
                    Button("执行门禁") { model.page = .execution }
                }
            }
            .sheet(isPresented: $showContract) { ContractVersionSheet(model: model, state: state) }
            Panel("科研流程") { Pipeline(current: state.phase.group) }
            Panel("Agent Events") {
                ForEach(Array(state.events.reversed())) { event in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(event.kind).fontWeight(.medium); Spacer(); Text(event.date, style: .time).foregroundStyle(.secondary) }
                        Text(event.detail).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(.vertical, 5)
                    Divider()
                }
            }
        }
    }
}
struct ContractVersionSheet: View {
    @Bindable var model: AppModel
    let state: ResearchSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var question = ""
    @State private var metric = ""
    @State private var constraints = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Research Contract · v" + String(state.contract.version + 1)).font(.title2)
            Form {
                TextField("名称", text: $title)
                TextField("研究目标", text: $question)
                TextField("主指标", text: $metric)
                TextField("约束", text: $constraints)
            }
            HStack { Button("取消") { dismiss() }; Spacer(); Button("保存新版本") { model.revise(title: title, question: question, metric: metric, constraints: constraints); dismiss() }.buttonStyle(.borderedProminent).disabled(title.isEmpty || question.isEmpty || metric.isEmpty) }
        }.padding(28).frame(width: 560)
            .onAppear { title = state.contract.title; question = state.contract.question; metric = state.contract.metric; constraints = state.contract.constraints }
    }
}
struct HypothesesView: View {
    @Bindable var model: AppModel
    @State private var selection: UUID?
    var body: some View {
        Panel("Hypothesis Tree") {
            ForEach(model.current?.hypotheses ?? []) { hypothesis in
                Button { selection = hypothesis.id } label: {
                    HStack { Image(systemName: hypothesis.evolved ? "arrow.triangle.branch" : "circle"); Text(hypothesis.title); Spacer(); StatusBadge(text: hypothesis.status.rawValue, status: hypothesis.status.rawValue) }
                }.buttonStyle(.plain).padding(.leading, hypothesis.evolved ? 22 : 0)
                if selection == hypothesis.id {
                    Text(hypothesis.mechanism).textSelection(.enabled)
                    Text(hypothesis.diagnostics).foregroundStyle(.secondary)
                    ForEach(hypothesis.noveltyReferences, id: \.self) { Text($0).textSelection(.enabled) }
                }
            }
            if model.current?.hypotheses.isEmpty != false { Text("—").foregroundStyle(.secondary) }
        }
    }
}
struct ExperimentsView: View {
    @Environment(ThemeManager.self) private var theme
    @Bindable var model: AppModel
    @State private var kind: ExperimentKind = .subset
    @State private var query = ""
    @State private var selected: UUID?
    @State private var page = 0
    private var filtered: [ExperimentRun] { (model.current?.runs ?? []).filter { ($0.kind == kind || kind == .subset && $0.kind == .reproduction) && (query.isEmpty || $0.id.uuidString.localizedCaseInsensitiveContains(query)) } }
    var body: some View {
        HStack {
            Picker("阶段", selection: $kind) { ForEach([ExperimentKind.subset, .fullSet, .ablation, .rebuttal], id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            TextField("搜索 Run ID", text: $query).frame(maxWidth: 180)
            Button("CSV") { exportCSV() }.disabled(filtered.isEmpty)
        }
        Panel("") {
            Table(Array(filtered.dropFirst(page * 20).prefix(20)), selection: $selected) {
                TableColumn("Run ID") { Text(String($0.id.uuidString.prefix(8))).font(.system(size: 10, design: .monospaced)) }
                TableColumn("Protocol") { Text(String($0.protocolHash.prefix(8))) }
                TableColumn("MSE") { Text($0.metrics["mse"].map { String(format: "%.6g", $0) } ?? "—") }
                TableColumn("Target") { Text($0.targetID) }
                TableColumn("Status") { StatusBadge(text: $0.state.rawValue, status: $0.state.rawValue) }
            }.frame(height: 260)
            HStack { Button("上一页") { page -= 1 }.disabled(page == 0); Text(String(page + 1)); Button("下一页") { page += 1 }.disabled((page + 1) * 20 >= filtered.count); Spacer() }
        }
        if let run = filtered.first(where: { $0.id == selected }) {
            Panel("Run Detail") {
                LabeledContent("Code", value: run.codeHash); LabeledContent("Data", value: run.dataHash)
                LabeledContent("Environment", value: run.environmentFingerprint)
                if let path = run.artifactPath { Button("查看产物") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
                Text(run.log).textSelection(.enabled)
                Chart(run.metrics.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                    BarMark(x: .value("Metric", entry.key), y: .value("Value", entry.value)).foregroundStyle(theme.accent)
                }.frame(height: 160)
            }.font(.system(size: 10, design: .monospaced))
        }
    }
    private func exportCSV() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "experiments.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rows = ["run_id,kind,status,target,mse,code_hash,data_hash"] + filtered.map { [$0.id.uuidString, $0.kind.rawValue, $0.state.rawValue, $0.targetID, $0.metrics["mse"].map(String.init(describing:)) ?? "", $0.codeHash, $0.dataHash].joined(separator: ",") }
        do { try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) } catch { model.error = error.localizedDescription }
    }
}
struct ReviewsView: View {
    @Bindable var model: AppModel
    private var canExport: Bool { guard var state = model.current else { return false }; state.exportConfirmed = true; return state.exportReady }
    var body: some View {
        Panel("Peer Review / Meta Review") {
            ForEach(model.current?.reviews ?? []) { review in Text(review.role.rawValue).fontWeight(.semibold); Text(review.text).textSelection(.enabled) }
            if model.current?.reviews.isEmpty != false { Text("—").foregroundStyle(.secondary) }
        }
        Panel("Integrity Audit") {
            ForEach(model.current?.integrity ?? []) { check in
                HStack(alignment: .top) { Text(check.id).fontWeight(.semibold); Text(check.detail).foregroundStyle(.secondary); Spacer(); StatusBadge(text: check.status.rawValue, status: check.status.rawValue) }
                Divider()
            }
        }
        if let manuscript = model.current?.manuscript, !manuscript.isEmpty { Panel("Manuscript") { Text(manuscript).textSelection(.enabled) } }
        Button("确认并导出研究") { model.exportResearch() }.disabled(!canExport || model.busy)
    }
}
struct ArtifactsView: View {
    @Bindable var model: AppModel
    var body: some View {
        Panel("Artifacts") {
            ForEach(model.current?.runs ?? []) { run in
                if let path = run.artifactPath {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: { Label(URL(fileURLWithPath: path).lastPathComponent + " · " + String(run.id.uuidString.prefix(8)), systemImage: "doc") }
                }
            }
        }
    }
}
