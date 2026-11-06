import SwiftUI
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(ThemeManager.self) private var theme
    @State private var section = "Appearance"
    @State private var hex = ""
    @AppStorage("research.defaultModel") private var selectedModel = "gpt-6.1-sol"
    @AppStorage("research.defaultReasoning") private var reasoning = "medium"
    private let sections = ["Accounts", "Models", "Research Defaults", "Compute Nodes", "Storage & Backup", "Security", "Advanced", "Appearance", "Environments"]
    var body: some View {
        @Bindable var theme = theme
        Picker("Settings", selection: $section) { ForEach(sections, id: \.self) { Text($0).tag($0) } }.frame(maxWidth: 240)
        switch section {
        case "Appearance":
            Panel("Appearance") {
                Picker("主题", selection: $theme.mode) { Text("System").tag(ThemeMode.system); Text("Light").tag(ThemeMode.light); Text("Dark").tag(ThemeMode.dark) }.pickerStyle(.segmented)
                Divider()
                Text("Accent Color").fontWeight(.medium)
                HStack(spacing: 14) {
                    ForEach(ThemeManager.accents, id: \.self) { value in
                        Button { theme.accentHex = value } label: {
                            Circle().fill(Color(hex: value)).frame(width: 28, height: 28)
                                .overlay { if theme.accentHex == value { Image(systemName: "checkmark").foregroundStyle(.white) } }
                        }.buttonStyle(.plain).accessibilityLabel(value)
                    }
                }
                ColorPicker("Custom", selection: Binding(get: { Color(hex: theme.customHex) }, set: { color in
                    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                    hex = String(format: "%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
                    _ = theme.saveCustom(hex)
                }), supportsOpacity: false)
                HStack {
                    TextField("HEX", text: $hex).textFieldStyle(.roundedBorder).frame(width: 130)
                    Circle().fill(Color(hex: ThemeManager.validHex(hex) ? hex : theme.accentHex)).frame(width: 22, height: 22)
                    Button("保存") { _ = theme.saveCustom(hex) }.disabled(!ThemeManager.validHex(hex))
                    Spacer(); Button("恢复默认") { theme.reset(); hex = theme.customHex }
                }
            }.onAppear { hex = theme.customHex }
        case "Accounts":
            Panel("Accounts") {
                LabeledContent("ChatGPT", value: model.account?.authenticated == true ? "Connected" : "Unknown")
                HStack { Button("Continue with ChatGPT") { model.login() }; Button("刷新") { model.checkAccount() } }
            }
        case "Models":
            Panel("Models") {
                Picker("Model", selection: $selectedModel) { ForEach(model.models) { Text($0.name).tag($0.id) } }
                Picker("Reasoning", selection: $reasoning) {
                    ForEach(model.models.first(where: { $0.id == selectedModel })?.reasoning ?? [], id: \.self) { Text($0).tag($0) }
                }
                Button("获取模型列表") { model.loadModels() }
            }
        case "Environments", "Compute Nodes": ComputeView(model: model)
        case "Research Defaults":
            Panel("paper_fidelity") {
                ForEach([("Limitation", "16"), ("Idea rounds", "4"), ("Successful ideas", "4"), ("Engineering", "2"), ("Ablation refinement", "1"), ("Peer review", "2"), ("Meta refinement", "1")], id: \.0) { row in LabeledContent(row.0, value: row.1) }
            }
        case "Storage & Backup":
            Panel("Storage") {
                Button("打开数据目录") { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NORMA")) }
                Button("备份研究与证据") { model.backup() }
            }
        case "Security":
            Panel("Security") { LabeledContent("Accounts", value: "Isolated profiles"); LabeledContent("Environment", value: "Read-only discovery"); LabeledContent("External compute", value: "Existing SSH targets only") }
        default:
            Panel("Advanced") { LabeledContent("IPC", value: "XPC v1"); LabeledContent("Codex protocol", value: "0.160.1"); Button("刷新服务状态") { Task { await model.refresh() } } }
        }
    }
}
