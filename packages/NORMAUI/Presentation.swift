import Foundation
import ResearchContracts

// Presentation only: persisted values and IPC contracts remain unchanged.
enum DisplayText {
    static func manuscript(_ text: String) -> String {
        text == NumericalSmoke.legacyReport ? NumericalSmoke.report : text
    }
    static func value(_ raw: String) -> String {
        labels[raw] ?? raw
    }
    static let labels: [String: String] = [
        "Sandbox": "受限执行环境", "Environment": "环境一致性",
        "noCandidate": "没有通过验证的候选方案", "noContribution": "实验未能支持方法贡献", "priorBest": "保留此前最佳结果",
        "unresolvedReview": "评审问题尚未解决", "budgetExhausted": "已达到授权额度", "integrityFailed": "研究依据核查未全部通过",
        "verified": "研究流程与依据核查完成", "smokeVerified": "内置数值验证完成",
        "knownProblemVerified": "已知问题研究流程验证完成",
        "Fit y=2x+1 to five points and independently reproduce the analytic solution": "用 5 个数据点拟合直线 y = 2x + 1，并用另一种方法核对结果",
        "ready": "等待开始", "queued": "排队中", "running": "运行中", "waitingApproval": "等待确认",
        "waitingAuth": "等待登录", "waitingResource": "等待可用算力", "paused": "已暂停", "cancelPending": "正在停止",
        "cancelled": "已停止", "failed": "执行失败", "unknown": "尚未确认", "succeeded": "已完成",
        "pass": "通过", "fail": "未通过", "PASS": "通过", "FAIL": "未通过",
        "untested": "尚未验证", "subsetGood": "初步验证通过", "fullGood": "完整验证通过", "bad": "验证未通过", "inconclusive": "结论不确定",
        "created": "准备研究", "limitations": "寻找研究问题", "seeds": "提出研究思路", "baseline": "建立对照实验",
        "subset": "小规模验证", "fullSet": "完整实验", "evolution": "改进研究思路", "selection": "选择研究方案",
        "ablation": "检验各部分作用", "refinement": "完善方案", "writing": "撰写报告", "peerReview": "评审报告",
        "rebuttal": "补充验证", "metaReview": "综合评审", "integrity": "核查研究依据", "finished": "研究结束", "reproduction": "独立复现",
        "local": "本机", "MSE": "均方误差（MSE）", "mse": "均方误差", "slope": "斜率", "intercept": "截距",
        "I1": "结果可复现", "I2": "实验符合方案", "I3": "引用可靠", "I4": "报告与实现一致",
        "Python": "Python", "Disk": "可用磁盘空间", "Scope": "实验规模", "Code": "实验程序一致性",
        "none": "不启用", "minimal": "最少", "low": "较少", "medium": "中等", "high": "较多", "xhigh": "高", "max": "最高", "ultra": "最高",
        "limitationExtractor": "寻找问题", "limitationVerifier": "核查问题", "seedGenerator": "提出思路", "noveltyChecker": "检查创新性", "evolver": "改进思路",
        "baselineCoder": "编写对照实验", "subsetCoder": "编写初步实验", "subsetCritic": "检查初步实验", "subsetEngineer": "修复初步实验",
        "fullSetCoder": "编写完整实验", "fullSetCritic": "检查完整实验", "fullSetEngineer": "修复完整实验", "selector": "选择方案",
        "ablationPlanner": "规划对比实验", "ablationCoder": "编写对比实验", "ablationCritic": "检查对比实验", "comparison": "分析结果",
        "writer": "撰写报告", "enhancer": "完善报告", "peerReviewer": "评审报告", "rebuttalPlanner": "规划补充验证", "rebuttalCoder": "执行补充验证",
        "metaReviewer": "综合评审", "scoreVerifier": "核查结果", "specificationAuditor": "核查实验方案", "referenceVerifier": "核查引用", "alignmentAuditor": "核查报告与实现"
    ]
    static func event(_ kind: String) -> String {
        ["autonomy.started": "自主研究已开始", "autonomy.stopped": "自主研究已停止", "role.started": "正在处理研究步骤", "role.completed": "研究步骤已完成", "phase.completed": "研究阶段已推进", "run.authorized": "实验已授权", "run.failed": "实验执行失败", "experiment.recorded": "实验结果已保存", "manuscript.saved": "中文报告已保存", "recovery.ready": "研究记录已恢复",
         "sources.updated": "研究资料已更新", "research.created": "已创建课题", "contract.created": "已创建课题", "plan.frozen": "已生成实验方案",
         "plan.userConfirmed": "已确认实验方案", "target.userSelected": "已选择执行设备", "preflight.completed": "已检查运行条件",
         "authorization.userApproved": "已授权本次实验", "smoke.queued": "验证实验已排队", "run.started": "实验已开始",
         "run.completed": "实验已结束", "smoke.completed": "微型验证已完成", "execution.stopped": "执行已停止",
         "recovery.required": "需要核对执行结果", "recovery.unresolved": "执行结果仍待确认", "recovery.cancelled": "已找回结果并停止执行",
         "research.paused": "课题已暂停", "research.resumed": "课题已恢复", "research.cancelRequested": "已请求停止课题",
         "contract.revised": "研究要求已更新", "export.userConfirmed": "已确认导出研究", "model.reserved": "已安排模型任务",
         "model.completed": "模型任务已完成"][kind] ?? "研究记录已更新"
    }
    static func checkDetail(_ check: Check) -> String {
        switch check.detail {
        case "Independent covariance rerun versus normal equations and analytic line y=2x+1": return "比较两种独立计算方法，并核对已知答案 y = 2x + 1。"
        case "Fixed five points; one batch, one seed, zero training steps": return "5 个数据点、1 个批次、1 个随机种子，不进行训练。"
        case "No research manuscript or literature claims in numerical smoke": return "本次数值验证不含文献引用，尚未进行引用核查。"
        case "Numerical smoke is not a manuscript/code alignment audit": return "本次数值验证不含研究报告，尚未核查报告与实现。"
        case "Five points, local CPU, no model invocation": return "5 个数据点，在本机运行，不调用模型。"
        default:
            if check.id == "Code" { return check.status == .pass ? "实验程序与已确认方案一致" : "需要重新核对实验程序" }
            if check.id == "Disk", let bytes = Int64(check.detail) { return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
            return check.detail
        }
    }
    static func error(_ error: Error) -> String {
        guard let error = error as? NormaError else { return "操作未完成，请重试或检查本机研究服务。" }
        switch error {
        case .conflict: return "课题已更新，请刷新后重试。"
        case .budgetExhausted: return "本次授权的使用额度已用完。"
        case .cancelled: return "操作已取消。"
        case .invalid, .unavailable, .forbidden:
            let detail = error.localizedDescription
            if detail.range(of: "[\\p{Han}]", options: .regularExpression) != nil { return detail }
            let known = ["Invalid preflight or selected target": "运行条件检查已失效，请重新检查。", "Environment drift": "运行环境已变化，请重新检查并授权。", "Missing, expired or revoked research authorization": "执行授权已失效，请重新授权。", "Model is outside approved scope": "当前模型调用不在授权范围内。"]
            return known[detail] ?? "操作未完成，请检查研究方案、登录状态和执行授权后重试。"
        }
    }
}

extension ResearchSnapshot {
    func nextStep(now: Date = Date()) -> String {
        if operation == .paused { return "恢复课题" }
        if operation == .cancelled || phase == .finished { return "查看实验结果" }
        if operation == .failed { return "查看失败记录" }
        if operation == .unknown { return "核对执行结果" }
        if operation == .running || operation == .queued || operation == .cancelPending { return "查看执行进度" }
        guard let plan else { return "准备实验方案" }
        if confirmedPlanHash != plan.hash { return "确认实验方案" }
        if selectedTargetID == nil { return "选择执行设备" }
        guard let report = preflight, report.passed, report.validUntil > now, report.planHash == plan.hash, report.targetID == selectedTargetID else { return "检查运行条件" }
        guard let auth = authorization, !auth.revoked, auth.expiresAt > now, auth.environmentFingerprint == report.environmentFingerprint, auth.target.id == selectedTargetID, (auth.usedRuns ?? reservedRuns) + 2 <= auth.maxRuns else { return "授权本次实验" }
        return "开始本机实验"
    }
}

extension ResearchSnapshot {
    /// Completed workflow steps, not an estimate of elapsed time or scientific success.
    func completedExecutionSteps(now: Date = Date()) -> Int {
        guard let plan else { return 0 }
        let currentRuns = runs.filter { $0.planHash == plan.hash }
        if !currentRuns.isEmpty {
            guard currentRuns.count >= 2, currentRuns.allSatisfy({ $0.state == .succeeded }) else { return 4 }
            return phase == .finished && integrity.contains(where: { $0.id == "I1" && $0.status != .unknown }) && integrity.contains(where: { $0.id == "I2" && $0.status != .unknown }) ? 6 : 5
        }
        guard confirmedPlanHash == plan.hash else { return 0 }
        guard selectedTargetID != nil else { return 1 }
        guard let report = preflight, report.passed, report.validUntil > now,
              report.planHash == plan.hash, report.targetID == selectedTargetID else { return 2 }
        guard let auth = authorization, !auth.revoked, auth.expiresAt > now,
              auth.researchID == id, auth.contractVersion == contract.version,
              auth.environmentFingerprint == report.environmentFingerprint, auth.target.id == selectedTargetID,
              (auth.usedRuns ?? reservedRuns) + 2 <= auth.maxRuns else { return 3 }
        return 4
    }
    var startActionTitle: String {
        if autonomy != nil {
            if phase == .finished { return "查看研究报告" }
            switch operation {
            case .failed, .paused: return "继续研究"
            case .unknown: return "恢复研究记录"
            case .waitingApproval: return "确认实验并继续"
            default: return "查看研究进度"
            }
        }
        if plan == nil && phase == .created { return "开始研究" }
        switch operation {
        case .paused, .unknown, .failed, .running, .queued, .cancelPending, .cancelled: return nextStep()
        default: return phase == .finished ? "查看实验结果" : "开始实验"
        }
    }
}
