import SwiftUI
import ResearchContracts

public struct NORMAAppShell: View {
    @State private var model: AppModel
    @State private var theme = ThemeManager()
    @State private var newResearch = false
    @Environment(\.colorScheme) private var scheme
    public init(model: AppModel) { _model = State(initialValue: model) }
    public var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) { Image(systemName: "sparkle").font(.title2).foregroundStyle(theme.accent); Text("NORMA").font(.system(size: 20, weight: .bold)) }
                    .padding(.horizontal, 18).padding(.top, 20)
                List {
                    ForEach(Page.primary) { page in
                        Button { model.page = page } label: {
                            HStack(spacing: 10) {
                                Image(systemName: page.icon).frame(width: 18)
                                Text(page.navigationTitle)
                            }.font(.system(size: 13))
                                .foregroundStyle((model.page == page || page == .workspace && model.page.isResearch) ? theme.accent : ThemeTokens(dark: scheme == .dark).primary)
                                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("nav." + String(describing: page))
                            .accessibilityAddTraits((model.page == page || page == .workspace && model.page.isResearch) ? .isSelected : [])
                            .listRowBackground((model.page == page || page == .workspace && model.page.isResearch) ? theme.accent.opacity(0.14) : Color.clear)
                    }
                    Section {
                        ForEach(model.researches) { state in
                            Button { model.selectedID = state.id; model.page = .workspace } label: {
                                HStack(spacing: 10) {
                                    Circle().fill(state.operation == .running ? Color.green : Color.secondary).frame(width: 6, height: 6)
                                        .frame(width: 18)
                                    Text(state.contract.title).lineLimit(2).multilineTextAlignment(.leading)
                                }.font(.system(size: 13))
                                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(model.selectedID == state.id && model.page.isResearch ? .isSelected : [])
                                .listRowBackground(model.selectedID == state.id && model.page.isResearch ? theme.accent.opacity(0.10) : Color.clear)
                        }
                        Button { newResearch = true } label: {
                            Label("新建课题", systemImage: "plus").font(.system(size: 13))
                                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    } header: {
                        Text("研究课题").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                Button { model.showWelcome = true } label: {
                    Label(model.account?.authenticated == true ? (model.account?.profile == "api" ? "API" : "ChatGPT") : "账户", systemImage: "person.crop.circle")
                }.buttonStyle(.plain).padding(18)
            }.background(ThemeTokens(dark: scheme == .dark).sidebar)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack {
                            Text(model.page.isResearch ? "课题工作台" : model.page.rawValue).font(.system(size: 23, weight: .semibold))
                            Spacer()
                            if model.demo { StatusBadge(text: "演示数据", status: "unknown") }
                            if model.busy { ProgressView().controlSize(.small) }
                        }
                        if let error = model.error {
                            HStack { Image(systemName: "exclamationmark.circle"); Text(error).textSelection(.enabled); Spacer(); Button("重试") { Task { await model.refresh() } } }
                                .font(.system(size: 11)).foregroundStyle(Color(hex: "E56B79"))
                        }
                        if model.page.isResearch {
                            if let state = model.current {
                                Text(state.contract.title).font(.system(size: 17, weight: .medium))
                                Picker("课题内容", selection: $model.page) {
                                    ForEach(Page.research) { Text($0.rawValue).tag($0) }
                                }.pickerStyle(.segmented).accessibilityIdentifier("research.tabs")
                                pageContent.id(state.id)
                            } else {
                                Button("新建课题") { newResearch = true }.buttonStyle(.borderedProminent)
                            }
                        } else { pageContent }
                    }.padding(28)
                }.frame(maxWidth: .infinity).background(ThemeTokens(dark: scheme == .dark).canvas)
                if model.showInspector && model.page.isResearch {
                    Divider()
                    InspectorPanel(model: model).frame(minWidth: 270, idealWidth: 330, maxWidth: 394)
                        .background(ThemeTokens(dark: scheme == .dark).surface)
                }
            }.toolbar {
                ToolbarItem(placement: .navigation) { Text(model.current?.contract.title ?? "NORMA").font(.system(size: 11)) }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { newResearch = true } label: { Image(systemName: "plus") }.accessibilityLabel("新建课题")
                    Button { withAnimation(.easeInOut(duration: 0.18)) { theme.toggle(resolved: scheme) } } label: { Image(systemName: scheme == .dark ? "sun.max" : "moon") }.accessibilityIdentifier("theme.toggle").accessibilityLabel("切换深浅主题")
                    Button { model.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }.accessibilityIdentifier("inspector.toggle").accessibilityLabel("课题详情").disabled(!model.page.isResearch)
                }
            }
        }
        .environment(theme).tint(theme.accent).preferredColorScheme(theme.preferredScheme)
        .font(.system(size: 11))
        .foregroundStyle(ThemeTokens(dark: scheme == .dark).primary)
        .frame(minWidth: 1120, minHeight: 720)
        .sheet(isPresented: $newResearch) { NewResearchSheet(model: model) }
        .sheet(isPresented: $model.showWelcome) { WelcomeView(model: model) }
        .task { await model.refresh() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if !model.busy { await model.refresh() }
            }
        }
        .environment(theme)
    }
    @ViewBuilder private var pageContent: some View {
        switch model.page {
        case .overview: OverviewView(model: model)
        case .workspace: WorkspaceView(model: model)
        case .hypotheses: HypothesesView(model: model)
        case .experiments: ExperimentsView(model: model)
        case .execution: ExecutionView(model: model)
        case .reviews: ReviewsView(model: model)
        case .compute: ComputeView(model: model)
        case .artifacts: ArtifactsView(model: model)
        case .settings: SettingsView(model: model)
        }
    }
}
struct Pipeline: View {
    @Environment(ThemeManager.self) private var theme
    let current: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(["提出思路", "实验验证", "分析结果", "撰写报告", "同行评审", "综合评审"].enumerated()), id: \.offset) { index, name in
                VStack(spacing: 9) {
                    Text(String(index + 1)).font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28)
                        .background(index == current ? theme.accent.opacity(0.3) : Color.secondary.opacity(0.12), in: Circle())
                    Text(name).font(.system(size: 10))
                }.frame(maxWidth: .infinity).foregroundStyle(index == current ? theme.accent : .secondary)
            }
        }.padding(.vertical, 10)
    }
}
struct InspectorPanel: View {
    @Bindable var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("课题详情").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                if let state = model.current {
                    Text(state.contract.title).font(.system(size: 16, weight: .semibold))
                    StatusBadge(text: state.operation.rawValue, status: state.operation.rawValue)
                    Divider()
                    info("研究要求", "第 \(state.contract.version) 版")
                    info("研究阶段", DisplayText.value(state.phase.rawValue))
                    info("模型调用次数", String(state.modelCalls))
                    info("执行设备", state.selectedTargetID.map(DisplayText.value) ?? "未选择")
                    DisclosureGroup("技术详情") { info("课题编号", state.id.uuidString); info("记录版本", String(state.revision)) }
                    Divider()
                    Text("核查结果").font(.system(size: 13, weight: .semibold))
                    ForEach(state.integrity) { check in HStack { Text(DisplayText.value(check.id)); Spacer(); StatusBadge(text: check.status.rawValue, status: check.status.rawValue) } }
                    if let error = state.lastError { DisclosureGroup("错误详情") { Text(error).textSelection(.enabled) } }
                } else { Text("—").foregroundStyle(.secondary) }
            }.font(.system(size: 11)).padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func info(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(label).foregroundStyle(.secondary); Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
    }
}
struct NewResearchSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = "最小二乘直线拟合"
    @State private var question = "验证五个点的最小二乘解是否与解析解一致"
    @State private var metric = "MSE"
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("新建课题").font(.title2)
            Form { TextField("研究名称", text: $title); TextField("研究问题", text: $question); TextField("评价指标", text: $metric) }
            HStack { Button("取消") { dismiss() }; Spacer(); Button("创建") { model.create(title: title, question: question, metric: metric); dismiss() }.buttonStyle(.borderedProminent).disabled(title.isEmpty || question.isEmpty) }
        }.padding(28).frame(width: 520)
    }
}
