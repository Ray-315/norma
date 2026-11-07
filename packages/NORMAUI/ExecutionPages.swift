import SwiftUI
import ResearchContracts
struct ExecutionView: View {
    @Environment(ThemeManager.self) private var theme
    @Bindable var model: AppModel
    @State private var showReport = false
    @State private var showApproval = false
    var body: some View {
        if model.current?.autonomy != nil { AutonomousExecutionView(model: model) }
        else {
        if let state = model.current {
            VStack(alignment: .leading, spacing: 22) {
            Panel("1. 确认实验方案") {
                Text(DisplayText.value(state.plan?.question ?? state.contract.question)).font(.system(size: 15, weight: .medium))
                if let plan = state.plan {
                    LabeledContent("验证内容", value: "用两种计算方法核对直线拟合的已知答案")
                    LabeledContent("数据规模", value: "5 个数据点，不进行训练")
                    DisclosureGroup("技术详情") {
                        LabeledContent("方案校验值", value: plan.protocolHash)
                        LabeledContent("代码校验值", value: plan.codeHash)
                        LabeledContent("数据校验值", value: plan.datasetHash)
                    }
                    Button(state.confirmedPlanHash == plan.hash ? "方案已确认" : "确认实验方案") { model.command("plan.confirm") }.disabled(state.confirmedPlanHash == plan.hash || model.busy)
                } else { Button("准备五点拟合验证") { model.command("smoke.prepare") } }
            }
            if let plan = state.plan, state.confirmedPlanHash == plan.hash {
                Panel("2. 选择执行设备") {
                    HStack(spacing: 16) {
                        target("本机实验", "desktopcomputer", enabled: !model.busy && !state.operation.occupiesSlot) { model.selectLocal() }
                        target("实验室服务器", "server.rack", enabled: false) {}
                        target("外部服务器", "network", enabled: false) {}
                    }
                    if state.selectedTargetID == "local" { Label("本机", systemImage: "checkmark.circle.fill").foregroundStyle(theme.accent) }
                    Button("检查运行条件") { model.command("target.preflight") }.disabled(state.selectedTargetID != "local" || model.busy || state.operation.occupiesSlot)
                }
            }
            if let report = state.preflight {
                Panel("3. 检查并授权执行") {
                    HStack { StatusBadge(text: report.validUntil <= Date() ? "检查已过期" : report.passed ? "通过" : "未通过", status: report.validUntil <= Date() ? "unknown" : report.passed ? "pass" : "fail"); Text(DisplayText.value(report.targetID)); Spacer(); Button("查看报告") { showReport = true } }
                    HStack {
                        Button("确认授权") { showApproval = true }.disabled(!report.passed || report.validUntil <= Date() || state.selectedTargetID != "local" || (state.authorization.map { !$0.revoked && $0.expiresAt > Date() && $0.environmentFingerprint == report.environmentFingerprint && ($0.usedRuns ?? state.reservedRuns) + 2 <= $0.maxRuns } ?? false) || model.busy || state.operation.occupiesSlot)
                        Button("开始实验", systemImage: "play.fill") { model.command("smoke.start") }.buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(state.authorization == nil || state.authorization?.revoked == true || (state.authorization?.expiresAt ?? .distantPast) <= Date() || report.validUntil <= Date() || !report.passed || state.authorization?.environmentFingerprint != report.environmentFingerprint || (state.authorization.map { ($0.usedRuns ?? state.reservedRuns) + 2 > $0.maxRuns } ?? true) || state.operation != .ready || model.busy)
                    }
                }
            }
            }.disabled(state.operation == .paused || state.operation == .cancelled || state.phase == .finished)
        }
        if model.current?.operation == .paused { Button("恢复课题") { model.command("research.resume") } }
        Color.clear.frame(height: 0)
            .sheet(isPresented: $showReport) { PreflightSheet(report: model.current?.preflight) }
            .sheet(isPresented: $showApproval) {
                VStack(alignment: .leading, spacing: 22) {
                    Text("授权本次本机实验").font(.title2)
                    LabeledContent("目标", value: model.node?.name ?? "本机")
                    LabeledContent("实验", value: "5 个数据点 · 1 个批次 · 1 个随机种子 · 不训练")
                    LabeledContent("模型调用", value: "不调用模型")
                    LabeledContent("运行上限", value: "最多运行 2 次，每次不超过 30 秒")
                    LabeledContent("有效期", value: "1 小时")
                    HStack { Button("取消") { showApproval = false }; Spacer(); Button("确认授权") { model.authorizeSmoke(); showApproval = false }.buttonStyle(.borderedProminent) }
                }.padding(28).frame(width: 520)
            }
        }
    }
    private func target(_ text: String, _ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { VStack(spacing: 12) { Image(systemName: icon).font(.system(size: 24)); Text(text) }.frame(maxWidth: .infinity).padding(.vertical, 20) }
            .buttonStyle(.bordered).disabled(!enabled)
    }
}
struct PreflightSheet: View {
    let report: TargetPreflightReport?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("运行条件检查结果").font(.title2)
            ForEach(report?.checks ?? []) { check in HStack { Text(DisplayText.value(check.id)); Spacer(); Text(DisplayText.checkDetail(check)); StatusBadge(text: check.status.rawValue, status: check.status.rawValue) } }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 560)
    }
}
struct ComputeView: View {
    @Bindable var model: AppModel
    var body: some View {
        Panel("执行设备") {
            HStack { Image(systemName: "desktopcomputer").font(.title); VStack(alignment: .leading) { Text(model.node?.name ?? "本机"); Text(ProcessInfo.processInfo.operatingSystemVersionString).foregroundStyle(.secondary) }; Spacer(); Button("检测") { model.discover() } }
            Divider()
            LabeledContent("CPU", value: String(ProcessInfo.processInfo.activeProcessorCount) + " 核")
            LabeledContent("内存", value: ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))
            if let environment = model.environment {
                LabeledContent("Python", value: environment.version)
                LabeledContent("处理器架构", value: environment.architecture)
                LabeledContent("可用磁盘空间", value: ByteCountFormatter.string(fromByteCount: environment.freeBytes, countStyle: .file))
            }
        }
        Panel("运行任务") {
            ForEach(model.researches.flatMap(\.runs).filter { $0.state.occupiesSlot }) { run in
                HStack {
                    Text(model.researches.first(where: { $0.runs.contains(where: { $0.id == run.id }) })?.contract.title ?? "实验")
                    Text(DisplayText.value(run.kind.rawValue)).foregroundStyle(.secondary)
                    Spacer(); StatusBadge(text: run.state.rawValue, status: run.state.rawValue)
                }
            }
        }
    }
}
struct WelcomeView: View {
    @Environment(ThemeManager.self) private var theme
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAPI = false
    @State private var apiKey = ""
    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "sparkle").font(.system(size: 48)).foregroundStyle(theme.accent)
            Text("NORMA").font(.system(size: 30, weight: .bold))
            Button("使用 ChatGPT 登录") { model.login() }.buttonStyle(.borderedProminent).controlSize(.large)
            Button("使用 API 密钥") { showAPI.toggle() }
            if showAPI {
                HStack {
                    SecureField("API 密钥", text: $apiKey)
                    Button("连接") { model.loginAPI(apiKey); apiKey = "" }.disabled(apiKey.isEmpty)
                }
            }
            Button("检查登录状态") { model.checkAccount() }
            if let account = model.account { StatusBadge(text: account.authenticated ? (account.profile == "api" ? "API 已连接" : "ChatGPT 已登录") : "未登录", status: account.authenticated ? "pass" : "unknown") }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            Button("完成") { dismiss() }
        }.padding(48).frame(width: 620).onAppear { showAPI = model.selectedProfile == "api" }
    }
}
