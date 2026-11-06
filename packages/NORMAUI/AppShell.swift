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
                List(Page.allCases) { page in
                    Button { model.page = page } label: {
                        HStack(spacing: 10) {
                            Image(systemName: page.icon).frame(width: 18)
                                .foregroundStyle(model.page == page ? theme.accent : ThemeTokens(dark: scheme == .dark).primary)
                            Text(page.rawValue).foregroundStyle(model.page == page ? theme.accent : ThemeTokens(dark: scheme == .dark).primary)
                        }.font(.system(size: 11))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("nav." + String(describing: page))
                        .accessibilityAddTraits(model.page == page ? .isSelected : [])
                        .listRowBackground(model.page == page ? theme.accent.opacity(0.14) : Color.clear)
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                VStack(alignment: .leading, spacing: 12) {
                    Text("研究课题").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(model.researches) { state in
                        Button { model.selectedID = state.id; model.page = .workspace } label: {
                            HStack { Circle().fill(state.operation == .running ? Color.green : Color.secondary).frame(width: 5, height: 5); Text(state.contract.title).lineLimit(1) }
                        }.buttonStyle(.plain).font(.system(size: 11))
                    }
                    Button("新建研究", systemImage: "plus") { newResearch = true }.font(.system(size: 11))
                }.padding(18)
                Button { model.showWelcome = true } label: {
                    Label(model.account?.authenticated == true ? (model.account?.profile == "api" ? "API" : "ChatGPT") : "账户", systemImage: "person.crop.circle")
                }.buttonStyle(.plain).padding(18)
            }.background(ThemeTokens(dark: scheme == .dark).sidebar)
                .navigationSplitViewColumnWidth(min: 200, ideal: 218, max: 240)
        } detail: {
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack {
                            Text(model.page.rawValue).font(.system(size: 23, weight: .semibold))
                            Spacer()
                            if model.demo { StatusBadge(text: "Demo", status: "unknown") }
                            if model.busy { ProgressView().controlSize(.small) }
                        }
                        if let error = model.error {
                            HStack { Image(systemName: "exclamationmark.circle"); Text(error).textSelection(.enabled); Spacer(); Button("重试") { Task { await model.refresh() } } }
                                .font(.system(size: 11)).foregroundStyle(Color(hex: "E56B79"))
                        }
                        pageContent
                    }.padding(28)
                }.frame(maxWidth: .infinity).background(ThemeTokens(dark: scheme == .dark).canvas)
                if model.showInspector {
                    Divider()
                    InspectorPanel(model: model).frame(minWidth: 270, idealWidth: 330, maxWidth: 394)
                        .background(ThemeTokens(dark: scheme == .dark).surface)
                }
            }.toolbar {
                ToolbarItem(placement: .navigation) { Text(model.current?.contract.title ?? "NORMA").font(.system(size: 11)) }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { newResearch = true } label: { Image(systemName: "plus") }.accessibilityLabel("新建研究")
                    Button { withAnimation(.easeInOut(duration: 0.18)) { theme.toggle(resolved: scheme) } } label: { Image(systemName: scheme == .dark ? "sun.max" : "moon") }.accessibilityIdentifier("theme.toggle")
                    Button { model.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }.accessibilityIdentifier("inspector.toggle")
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
            ForEach(Array(["Idea", "Evaluator", "Analyzer", "Writer", "Peer", "Meta"].enumerated()), id: \.offset) { index, name in
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
                Text("INSPECTOR").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                if let state = model.current {
                    Text(state.contract.title).font(.system(size: 16, weight: .semibold))
                    StatusBadge(text: state.operation.rawValue, status: state.operation.rawValue)
                    Divider()
                    info("Research ID", state.id.uuidString)
                    info("Contract", "v" + String(state.contract.version))
                    info("Phase", state.phase.rawValue)
                    info("Revision", String(state.revision))
                    info("Model calls", String(state.modelCalls))
                    info("Target", state.authorization?.target.name ?? "—")
                    Divider()
                    Text("证据").font(.system(size: 13, weight: .semibold))
                    ForEach(state.integrity) { check in HStack { Text(check.id); Spacer(); StatusBadge(text: check.status.rawValue, status: check.status.rawValue) } }
                    if let error = state.lastError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
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
            Text("Research Contract").font(.title2)
            Form { TextField("研究名称", text: $title); TextField("研究问题", text: $question); TextField("主指标", text: $metric) }
            HStack { Button("取消") { dismiss() }; Spacer(); Button("创建") { model.create(title: title, question: question, metric: metric); dismiss() }.buttonStyle(.borderedProminent).disabled(title.isEmpty || question.isEmpty) }
        }.padding(28).frame(width: 520)
    }
}
