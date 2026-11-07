import SwiftUI
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(ThemeManager.self) private var theme
    @State private var section = "账户与模型"
    @State private var hex = ""
    @AppStorage("research.defaultModel") private var selectedModel = "gpt-6.1-sol"
    @AppStorage("research.defaultReasoning") private var reasoning = "medium"
    private let sections = ["账户与模型", "外观", "数据与备份"]
    var body: some View {
        @Bindable var theme = theme
        Picker("设置分类", selection: $section) { ForEach(sections, id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
        switch section {
        case "外观":
            Panel("外观") {
                Picker("主题", selection: $theme.mode) { Text("跟随系统").tag(ThemeMode.system); Text("浅色").tag(ThemeMode.light); Text("深色").tag(ThemeMode.dark) }.pickerStyle(.segmented)
                Divider()
                Text("强调色").fontWeight(.medium)
                HStack(spacing: 14) {
                    ForEach(Array(ThemeManager.accents.enumerated()), id: \.element) { index, value in
                        Button { theme.accentHex = value } label: {
                            Circle().fill(Color(hex: value)).frame(width: 28, height: 28)
                                .overlay { if theme.accentHex == value { Image(systemName: "checkmark").foregroundStyle(.white) } }
                        }.buttonStyle(.plain).accessibilityLabel(["紫色", "蓝色", "青色", "绿色", "橙色", "粉色"][index])
                    }
                }
                ColorPicker("自定义颜色", selection: Binding(get: { Color(hex: theme.customHex) }, set: { color in
                    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                    hex = String(format: "%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
                    _ = theme.saveCustom(hex)
                }), supportsOpacity: false)
                HStack {
                    TextField("颜色代码（HEX）", text: $hex).textFieldStyle(.roundedBorder).frame(width: 160)
                    Circle().fill(Color(hex: ThemeManager.validHex(hex) ? hex : theme.accentHex)).frame(width: 22, height: 22)
                    Button("保存颜色") { _ = theme.saveCustom(hex) }.disabled(!ThemeManager.validHex(hex))
                    Spacer(); Button("恢复默认") { theme.reset(); hex = theme.customHex }
                }
            }.onAppear { hex = theme.customHex }
        case "账户与模型":
            Panel("登录账户") {
                Picker("登录方式", selection: $model.selectedProfile) { Text("ChatGPT").tag("chatgpt"); Text("API 密钥").tag("api") }
                    .onChange(of: model.selectedProfile) { _, _ in model.account = nil; model.models = [] }
                LabeledContent("登录状态", value: model.account?.profile == model.selectedProfile ? (model.account?.authenticated == true ? "已登录" : "未登录") : "尚未检查")
                HStack {
                    Button(model.selectedProfile == "chatgpt" ? "使用 ChatGPT 登录" : "输入 API 密钥") { model.showWelcome = true }
                    Button("检查登录状态") { model.checkAccount() }
                }
            }
            Panel("默认模型") {
                Picker("模型", selection: $selectedModel) {
                    if !model.models.contains(where: { $0.id == selectedModel }) { Text(selectedModel).tag(selectedModel) }
                    ForEach(model.models) { Text($0.name).tag($0.id) }
                }
                Picker("思考程度", selection: $reasoning) {
                    let levels = model.models.first(where: { $0.id == selectedModel })?.reasoning ?? []
                    if !levels.contains(reasoning) { Text(DisplayText.value(reasoning)).tag(reasoning) }
                    ForEach(levels, id: \.self) { Text(DisplayText.value($0)).tag($0) }
                }
                Button("获取可用模型") { model.loadModels() }
            }
        default:
            Panel("研究数据") {
                Button("打开数据文件夹") { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NORMA")) }
                Button("备份研究与证据") { model.backup() }
            }
        }
    }
}
