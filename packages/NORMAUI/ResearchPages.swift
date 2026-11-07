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
        Panel("研究课题") {
            ForEach(model.researches) { state in
                Button { model.selectedID = state.id; model.page = .workspace } label: {
                    HStack { VStack(alignment: .leading, spacing: 7) { Text(state.contract.title).fontWeight(.medium); Text(state.contract.question).foregroundStyle(.secondary).lineLimit(2) }; Spacer(); StatusBadge(text: state.operation.rawValue, status: state.operation.rawValue) }.padding(.vertical, 7)
                }.buttonStyle(.plain)
                Divider()
            }
            if model.researches.isEmpty { Text("尚未创建课题").foregroundStyle(.secondary) }
        }
        Panel("当前课题动态") {
            ForEach(Array((model.current?.events ?? []).reversed().prefix(8))) { event in
                HStack(alignment: .top) { Circle().fill(theme.accent).frame(width: 5, height: 5).padding(.top, 5); Text(DisplayText.event(event.kind)); Spacer(); Text(event.date, style: .time).foregroundStyle(.secondary) }
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
    @State private var showResearchStart = false
    var body: some View {
        if let state = model.current {
            Panel("研究要求 · 第 \(state.contract.version) 版") {
                Text(state.contract.question).font(.system(size: 17, weight: .medium))
                LabeledContent("评价指标", value: DisplayText.value(state.contract.metric))
                if !state.contract.constraints.isEmpty { Text(state.contract.constraints).foregroundStyle(.secondary) }
                HStack {
                    Button("修改研究要求") { showContract = true }.disabled(state.operation.occupiesSlot)
                    Menu("课题操作") {
                        Button("暂停课题", systemImage: "pause") { model.command("research.pause") }
                            .disabled((state.operation.occupiesSlot && state.autonomy == nil) || state.operation == .paused || state.operation == .cancelled || state.phase == .finished)
                        Button("恢复课题", systemImage: "play") { model.command("research.resume") }.disabled(state.operation != .paused)
                        Button("停止课题", systemImage: "stop") { model.command("research.cancel") }.disabled(state.operation == .cancelled || state.phase == .finished)
                    }.disabled(model.busy)
                    Spacer()
                    Button {
                        if state.autonomy == nil && state.plan == nil { showResearchStart = true }
                        else if state.autonomy != nil {
                            if state.operation == .paused || state.operation == .failed { model.command("autonomy.resume") }
                            else if state.operation == .unknown { model.command("research.reconcile") }
                            else { model.page = state.operation == .waitingApproval ? .execution : state.phase == .finished ? .reviews : .hypotheses }
                        }
                        else if state.operation == .paused { model.command("research.resume") }
                        else if state.operation == .unknown { model.command("research.reconcile") }
                        else if state.operation == .ready && state.completedExecutionSteps() == 4 { model.command("smoke.start"); model.page = .experiments }
                        else { model.page = state.phase == .finished || state.operation == .cancelled || state.operation.occupiesSlot || state.operation == .queued || state.operation == .failed ? .experiments : .execution }
                    } label: {
                        Label(state.startActionTitle, systemImage: state.startActionTitle == "开始实验" ? "play.fill" : "arrow.right")
                            .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 10)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
                        .accessibilityIdentifier("research.start")
                }
            }
            .sheet(isPresented: $showContract) { ContractVersionSheet(model: model, state: state) }
            .sheet(isPresented: $showResearchStart) { ResearchStartSheet(model: model, state: state) }
            if state.autonomy != nil { AutonomousProgressView(state: state) }
            else { ExecutionProgressView(state: state) }
            ResearchSourcesView(model: model)
            TokenUsageView(state: state)
            ActivityLogView(events: state.events)
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
    @State private var expandedField: LongTextField?
    private enum LongTextField: String { case question = "研究目标", constraints = "约束" }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let field = expandedField {
                Text(field.rawValue).font(.title2)
                TextEditor(text: field == .question ? $question : $constraints)
                    .font(.system(size: 14)).lineSpacing(5)
                    .padding(12).background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                    .accessibilityLabel(field.rawValue).accessibilityIdentifier("research.longTextEditor")
                HStack { Spacer(); Button("返回表单") { expandedField = nil }.buttonStyle(.borderedProminent) }
            } else {
                Text("修改研究要求 · 第 \(state.contract.version + 1) 版").font(.title2)
                Form {
                    TextField("名称", text: $title)
                    LabeledContent("研究目标") {
                        VStack(alignment: .trailing, spacing: 6) {
                            TextField("研究目标", text: $question, axis: .vertical).labelsHidden().lineLimit(3...6)
                            Button("展开编辑", systemImage: "arrow.up.left.and.arrow.down.right") { expandedField = .question }
                                .accessibilityIdentifier("research.expandQuestion")
                        }
                    }
                    TextField("评价指标", text: $metric)
                    LabeledContent("约束") {
                        VStack(alignment: .trailing, spacing: 6) {
                            TextField("约束", text: $constraints, axis: .vertical).labelsHidden().lineLimit(4...8)
                            Button("展开编辑", systemImage: "arrow.up.left.and.arrow.down.right") { expandedField = .constraints }
                                .accessibilityIdentifier("research.expandConstraints")
                        }
                    }
                }
                HStack { Button("取消") { dismiss() }; Spacer(); Button("保存新版本") { model.revise(title: title, question: question, metric: metric, constraints: constraints); dismiss() }.buttonStyle(.borderedProminent).disabled(title.isEmpty || question.isEmpty || metric.isEmpty) }
            }
        }.padding(28).frame(width: expandedField == nil ? 680 : 840, height: expandedField == nil ? nil : 640)
            .onAppear { title = state.contract.title; question = state.contract.question; metric = state.contract.metric; constraints = state.contract.constraints }
    }
}

struct HypothesesView: View {
    @Bindable var model: AppModel
    @State private var selection: UUID?
    var body: some View {
        Panel("研究思路") {
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
            if model.current?.hypotheses.isEmpty != false {
                if NumericalSmoke.matches(model.current?.plan) {
                    Text(NumericalSmoke.method).textSelection(.enabled)
                } else {
                    Text("尚未生成研究思路").foregroundStyle(.secondary)
                }
            }
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
            Picker("阶段", selection: $kind) { ForEach([ExperimentKind.subset, .fullSet, .ablation, .rebuttal], id: \.self) { Text(DisplayText.value($0.rawValue)).tag($0) } }.pickerStyle(.segmented).onChange(of: kind) { _, _ in page = 0; selected = nil }
            TextField("搜索实验编号", text: $query).frame(maxWidth: 180).onChange(of: query) { _, _ in page = 0; selected = nil }
            Button("导出 CSV") { exportCSV() }.disabled(filtered.isEmpty)
        }
        Panel("实验记录") {
            if filtered.isEmpty { Text("尚无符合条件的实验记录").foregroundStyle(.secondary) }
            Table(Array(filtered.dropFirst(page * 20).prefix(20)), selection: $selected) {
                TableColumn("实验编号") { Text(String($0.id.uuidString.prefix(8))).font(.system(size: 10, design: .monospaced)) }
                TableColumn("实验类型") { Text(DisplayText.value($0.kind.rawValue)) }
                TableColumn("均方误差") { Text($0.metrics["mse"].map { String(format: "%.6g", $0) } ?? "—") }
                TableColumn("执行设备") { Text(DisplayText.value($0.targetID)) }
                TableColumn("状态") { StatusBadge(text: $0.state.rawValue, status: $0.state.rawValue) }
            }.frame(height: 260)
            HStack { Button("上一页") { page -= 1 }.disabled(page == 0); Text(String(page + 1)); Button("下一页") { page += 1 }.disabled((page + 1) * 20 >= filtered.count); Spacer() }
        }
        if let run = filtered.first(where: { $0.id == selected }) {
            Panel("实验详情") {
                DisclosureGroup("技术详情") {
                    LabeledContent("代码校验值", value: run.codeHash); LabeledContent("数据校验值", value: run.dataHash)
                    LabeledContent("环境校验值", value: run.environmentFingerprint)
                    Text(run.log).textSelection(.enabled)
                }
                if let path = run.artifactPath { Button("打开结果文件") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
                Chart(run.metrics.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                    BarMark(x: .value("指标", DisplayText.value(entry.key)), y: .value("数值", entry.value)).foregroundStyle(theme.accent)
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
        Panel("评审意见") {
            ForEach(model.current?.reviews ?? []) { review in Text(DisplayText.value(review.role.rawValue)).fontWeight(.semibold); Text(review.text).textSelection(.enabled) }
            if model.current?.reviews.isEmpty != false { Text("尚未产生评审意见").foregroundStyle(.secondary) }
        }
        Panel("研究依据核查") {
            ForEach(model.current?.integrity ?? []) { check in
                HStack(alignment: .top) { Text(DisplayText.value(check.id)).fontWeight(.semibold); Text(DisplayText.checkDetail(check)).foregroundStyle(.secondary); Spacer(); StatusBadge(text: check.status.rawValue, status: check.status.rawValue) }
                Divider()
            }
        }
        if let manuscript = model.current?.manuscript, !manuscript.isEmpty { Panel("研究报告") { Text(DisplayText.manuscript(manuscript)).textSelection(.enabled) } }
        Button("确认并导出研究") { model.exportResearch() }.disabled(!canExport || model.busy)
    }
}
struct ArtifactsView: View {
    @Bindable var model: AppModel
    var body: some View {
        Panel("研究文件") {
            if model.current?.runs.contains(where: { $0.artifactPath != nil }) != true { Text("实验完成后可在这里查看结果文件").foregroundStyle(.secondary) }
            ForEach(model.current?.runs ?? []) { run in
                if let path = run.artifactPath {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: { Label(URL(fileURLWithPath: path).lastPathComponent + " · " + String(run.id.uuidString.prefix(8)), systemImage: "doc") }
                }
            }
        }
    }
}

struct ExecutionProgressView: View {
    @Environment(ThemeManager.self) private var theme
    let state: ResearchSnapshot
    private let steps = ["确认方案", "选择设备", "检查环境", "授权执行", "运行实验", "核查结果"]
    var body: some View {
        let completed = state.completedExecutionSteps()
        Panel("本机实验进度") {
            HStack {
                Text("已完成 \(completed) / \(steps.count) 步").foregroundStyle(.secondary)
                Spacer()
                StatusBadge(text: state.operation.rawValue, status: state.operation.rawValue)
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                    VStack(alignment: .leading, spacing: 10) {
                        Capsule().fill(index < completed ? theme.accent : Color.secondary.opacity(0.16)).frame(height: 6)
                        HStack(spacing: 5) {
                            Image(systemName: index < completed ? "checkmark.circle.fill" : index == completed ? "circle.inset.filled" : "circle")
                            Text(title)
                        }.font(.system(size: 11, weight: index == completed ? .semibold : .regular))
                            .foregroundStyle(index <= completed ? theme.accent : Color.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.accessibilityElement(children: .ignore)
                .accessibilityLabel("本机实验进度")
                .accessibilityValue("已完成 \(completed) 步，共 \(steps.count) 步")
            if completed < steps.count { Text(state.nextStep()).foregroundStyle(.secondary) }
        }
    }
}

struct ActivityLogView: View {
    let events: [AuditEvent]
    @State private var expanded = false
    var body: some View {
        Panel("") {
            DisclosureGroup(isExpanded: $expanded) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(events.reversed())) { event in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(event.kind)
                                    Text(event.detail)
                                }.font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled).padding(.vertical, 4)
                            } label: {
                                HStack(spacing: 12) {
                                    Text(event.date, style: .time).monospacedDigit()
                                        .foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                                    Text(DisplayText.event(event.kind)).lineLimit(1)
                                    Spacer(minLength: 8)
                                    if event.kind == "preflight.completed" || event.kind == "target.userSelected" {
                                        Text(DisplayText.value(event.detail)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }.font(.system(size: 11)).padding(.vertical, 3)
                            }
                        }
                    }.padding(.top, 8).padding(.trailing, 8)
                }.frame(height: min(CGFloat(events.count * 32 + 8), 240))
            } label: {
                HStack {
                    Text("操作记录").font(.system(size: 13, weight: .semibold))
                    Text("\(events.count) 条").font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityIdentifier("research.activityLog")
        }
    }
}

struct ResearchSourcesView: View {
    @Bindable var model: AppModel
    @State private var preview: String?
    @State private var previewing = false
    var body: some View {
        Panel("研究资料") {
            HStack {
                Button("添加附件", systemImage: "paperclip") { model.chooseSources(project: false) }
                Button("选择项目文件夹", systemImage: "folder") { model.chooseSources(project: true) }
                Spacer()
                Button("查看读取内容") {
                    guard let id = model.current?.id else { return }
                    previewing = true
                    Task {
                        defer { previewing = false }
                        do { preview = try await model.client.call("sources.preview", id, as: String.self) }
                        catch { model.error = DisplayText.error(error) }
                    }
                }.disabled((model.current?.sources ?? []).isEmpty || previewing)
            }.disabled(model.busy || model.current?.operation.occupiesSlot == true)
            ForEach(model.current?.sources ?? []) { source in
                HStack(spacing: 10) {
                    Image(systemName: source.kind == .project ? "folder" : "doc")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name).lineLimit(1)
                        if let path = source.path { Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }
                    }
                    Spacer()
                    if let object = source.artifact { Text(ByteCountFormatter.string(fromByteCount: Int64(object.byteCount), countStyle: .file)).foregroundStyle(.secondary) }
                    Button("移除") { model.removeSource(source.id) }.disabled(model.busy || model.current?.operation.occupiesSlot == true)
                }
            }
        }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Agent 将读取的研究资料").font(.title2)
                ScrollView { Text(preview?.isEmpty == false ? preview! : "未找到可读取的文本资料").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("关闭") { preview = nil } }
            }.padding(28).frame(width: 800, height: 600)
        }
    }
}
struct TokenUsageView: View {
    let state: ResearchSnapshot
    var body: some View {
        let summary = state.tokenUsage
        let recorded = summary?.recordedCalls ?? 0
        Panel("Token 用量") {
            if state.modelCalls == 0 && recorded == 0 { LabeledContent("已使用", value: "0") }
            else if recorded == 0 { Text("未记录").foregroundStyle(.secondary) }
            else if let usage = summary?.usage {
                HStack {
                    LabeledContent("已记录总量", value: usage.totalTokens.formatted())
                    Spacer()
                    LabeledContent("输入", value: usage.inputTokens.formatted())
                    Spacer()
                    LabeledContent("输出", value: usage.outputTokens.formatted())
                }
                DisclosureGroup("用量明细") {
                    LabeledContent("输入中的缓存命中", value: usage.cachedInputTokens.formatted())
                    LabeledContent("输出中的推理用量", value: usage.reasoningOutputTokens.formatted())
                }
            }
            if state.modelCalls > recorded { LabeledContent("未返回用量的调用", value: String(state.modelCalls - recorded)) }
        }
    }
}
