import SwiftUI
import ResearchContracts
struct ExecutionView: View {
    @Environment(ThemeManager.self) private var theme
    @Bindable var model: AppModel
    @State private var showReport = false
    @State private var showApproval = false
    var body: some View {
        if let state = model.current {
            Panel("Experiment Plan") {
                Text(state.plan?.question ?? state.contract.question).font(.system(size: 15, weight: .medium))
                if let plan = state.plan {
                    LabeledContent("Protocol", value: String(plan.protocolHash.prefix(16)))
                    LabeledContent("Code", value: String(plan.codeHash.prefix(16)))
                    LabeledContent("Data", value: String(plan.datasetHash.prefix(16)))
                    Button("确认实验方案") { model.command("plan.confirm") }.disabled(state.confirmedPlanHash == plan.hash || model.busy)
                } else { Button("生成微型验证方案") { model.command("smoke.prepare") } }
            }
            if let plan = state.plan, state.confirmedPlanHash == plan.hash {
                Panel("执行目标") {
                    HStack(spacing: 16) {
                        target("本机实验", "desktopcomputer", enabled: !model.busy && !state.operation.occupiesSlot) { model.selectLocal() }
                        target("Lab 服务器", "server.rack", enabled: false) {}
                        target("外部服务器", "network", enabled: false) {}
                    }
                    if state.selectedTargetID == "local" { Label("本机", systemImage: "checkmark.circle.fill").foregroundStyle(theme.accent) }
                    Button("检查运行条件") { model.command("target.preflight") }.disabled(state.selectedTargetID != "local" || model.busy || state.operation.occupiesSlot)
                }
            }
            if let report = state.preflight {
                Panel("Target Preflight") {
                    HStack { StatusBadge(text: report.passed ? "PASS" : "FAIL", status: report.passed ? "pass" : "fail"); Text(report.targetID); Spacer(); Button("查看报告") { showReport = true } }
                    HStack {
                        Button("确认授权") { showApproval = true }.disabled(!report.passed || state.selectedTargetID != "local" || state.authorization != nil || model.busy)
                        Button("启动实验") { model.command("smoke.start") }.buttonStyle(.borderedProminent)
                            .disabled(state.authorization == nil || state.operation != .ready || model.busy)
                    }
                }
            }
        }
        Color.clear.frame(height: 0)
            .sheet(isPresented: $showReport) { PreflightSheet(report: model.current?.preflight) }
            .sheet(isPresented: $showApproval) {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Execution Authorization").font(.title2)
                    LabeledContent("目标", value: model.node?.name ?? "本机")
                    LabeledContent("实验", value: "5 points · 1 batch · 1 seed · 0 steps")
                    LabeledContent("调用预算", value: "0 model calls")
                    LabeledContent("执行预算", value: "2 runs · 30 seconds / run")
                    LabeledContent("有效期", value: "1 hour")
                    HStack { Button("取消") { showApproval = false }; Spacer(); Button("确认授权") { model.authorizeSmoke(); showApproval = false }.buttonStyle(.borderedProminent) }
                }.padding(28).frame(width: 520)
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
            Text("Target Preflight Result").font(.title2)
            ForEach(report?.checks ?? []) { check in HStack { Text(check.id); Spacer(); Text(check.detail); StatusBadge(text: check.status.rawValue, status: check.status.rawValue) } }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 560)
    }
}
struct ComputeView: View {
    @Bindable var model: AppModel
    var body: some View {
        Panel("Compute Nodes") {
            HStack { Image(systemName: "desktopcomputer").font(.title); VStack(alignment: .leading) { Text(model.node?.name ?? "本机"); Text(ProcessInfo.processInfo.operatingSystemVersionString).foregroundStyle(.secondary) }; Spacer(); Button("检测") { model.discover() } }
            Divider()
            LabeledContent("CPU", value: String(ProcessInfo.processInfo.activeProcessorCount) + " cores")
            LabeledContent("RAM", value: ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))
            if let environment = model.environment {
                LabeledContent("Python", value: environment.version)
                LabeledContent("Architecture", value: environment.architecture)
                LabeledContent("Disk", value: ByteCountFormatter.string(fromByteCount: environment.freeBytes, countStyle: .file))
            }
        }
        Panel("运行任务") {
            ForEach(model.researches.flatMap(\.runs).filter { $0.state.occupiesSlot }) { run in
                HStack { Text(run.id.uuidString); Spacer(); StatusBadge(text: run.state.rawValue, status: run.state.rawValue) }
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
            Pipeline(current: 0)
            Button("Continue with ChatGPT") { model.login() }.buttonStyle(.borderedProminent).controlSize(.large)
            Button("Use API Key") { showAPI.toggle() }
            if showAPI {
                HStack {
                    SecureField("API Key", text: $apiKey)
                    Button("连接") { model.loginAPI(apiKey); apiKey = "" }.disabled(apiKey.isEmpty)
                }
            }
            Button("检查登录状态") { model.checkAccount() }
            if let account = model.account { StatusBadge(text: account.authenticated ? account.profile + " Connected" : "Not connected", status: account.authenticated ? "pass" : "unknown") }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            Button("完成") { dismiss() }
        }.padding(48).frame(width: 620)
    }
}
