import Foundation
import ResearchContracts
import EvidenceEngine

public enum AutonomousPolicy {
    static func assignment(_ role: Role) -> String {
        switch role {
        case .limitationExtractor:
            "这是实验前的问题识别：根据研究要求和已有资料提出待检验的问题、假设边界与可测局限。此时尚无运行记录是正常的，不应仅因还没做实验而判定没有候选。已知问题验证可直接以数学结论作为待验证的参照，decision 用 continue；不得称其已被程序验证。"
        case .limitationVerifier:
            "检查上一角色提出的问题是否明确、在授权数据和执行范围内可检验。此阶段不要求实验结果，也不提前判断实验成功。已知问题验证不要求发现新科学局限；可检验则 accept，问题或资料确实不足才 reject。"
        case .seedGenerator:
            "生成至少 2 个不同、具体且可执行的候选方法。使用全新的 UUID；不得重复已有候选编号。每个方法说明机制与可检验预测。已知问题验证不需要编造创新性或文献。"
        case .noveltyChecker:
            "核查候选机制及依据。已知问题模式只检查方法明确、可实施且不作创新宣称，通过则 accept；新研究模式必须为至少两条参考资料提供 citations，以附件原文支持其论断，不能把未经核查的参考文献当作已核实。"
        case .baselineCoder:
            "编写基线程序，返回 experiment；不能返回执行结果。即使没有运行记录也必须先提出可执行代码。只用已授权数据，返回约定指标及必要的数值结果供后续核查。"
        case .selector:
            "根据已有 fullGood 候选及真实实验选择最佳方案，返回已有 candidateID；不能生成新方案代替选择。"
        case .writer, .enhancer:
            "基于实际实验和完整失败记录撰写或完善完整中文报告，保留局限与未解决项。报告正文引用完整运行 UUID，输出 evidenceIDs。不得只返回一段摘要。若已有审计拒绝意见，应据此修订报告措辞，不得篡改实验记录。评审状态必须明确区分历史稿件和本次修订稿，不写会在后续评审后过时的‘尚未开展评审’；可注明当前稿件以其后保存的评审记录为准。内部阶段名称用中文表述。"
        case .peerReviewer, .scoreVerifier:
            "按研究合同和运行范围评价科学表述、可复现性与证据完整性。已知问题验证不以创新性或更大数据集为评分条件，但不得放宽真实性要求。必须给出 0–10 的 score；仅文字修改不属于 empiricalObjections，缺少实际实验支持才为 true。"
        case .metaReviewer:
            "结合同行意见、报告及实际证据作出 accept/reject。已知问题模式检查验证过程是否严谨、结论是否如实且限于授权数据，不要求新发现；不能把精度持平写成新贡献。"
        case .specificationAuditor:
            "核查支撑当前报告结论的成功实验，其代码、输入、指标、样本规模、批次、种子及执行记录是否符合研究要求；发现不符则 reject，不能仅凭成功退出判定符合要求。同时核对失败/取消记录是否如实披露、是否被隔离且未充作成功证据。被执行器拒绝的早期方案仍是不合规的失败尝试，后续修订不能追认它合规；但失败已隔离、未污染结论且修订后的成功实验符合要求时，不应仅因历史存在失败而永久拒绝当前报告。批次、种子、步数的依据是附带的实际执行器返回清单，不仅是模型代码是否显式设置。"
        case .referenceVerifier:
            "核查报告是否含无依据的外部文献、创新性或事实声明。已知问题验证若没有外部引用则明确记录其不适用，references 为空且可 accept；存在外部引用必须列入 references，不得伪装为已完成独立核实。"
        case .alignmentAuditor:
            "对照全部提交代码、输入和实际输出检查报告中的方法、指标、结论与局限，真实一致才 accept。不得将复现一致等同于科研贡献。"
        default:
            "完成当前角色对应的实现、诊断、比较或评审职责。只有给定真实证据支持时才能作肯定结论；没有贡献、失败或无法判定都是允许的结果。"
        }
    }
    static let codingRoles: Set<Role> = [.baselineCoder, .subsetCoder, .subsetEngineer, .fullSetCoder, .fullSetEngineer, .ablationCoder, .rebuttalCoder]
    static func roles(for state: WorkflowState) -> [Role] {
        switch state.phase {
        case .limitations: [.limitationExtractor, .limitationVerifier]
        case .seeds: [.seedGenerator, .noveltyChecker]
        case .baseline: [.baselineCoder]
        case .subset: [state.engineeringAttempts > 0 ? .subsetEngineer : .subsetCoder, .subsetCritic]
        case .fullSet: [state.engineeringAttempts > 0 ? .fullSetEngineer : .fullSetCoder, .fullSetCritic]
        case .evolution: state.successes >= state.profile.successThreshold || state.round + 1 >= state.profile.ideaRounds ? [] : [.seedGenerator, .evolver]
        case .selection: [.selector]
        case .ablation: [.ablationPlanner, .ablationCoder, .ablationCritic]
        case .refinement: [.fullSetEngineer, .comparison]
        case .writing: [.writer, .enhancer]
        case .peerReview: [.peerReviewer, .scoreVerifier]
        case .rebuttal: [.rebuttalPlanner, .rebuttalCoder]
        case .metaReview: [.metaReviewer]
        case .integrity: [.specificationAuditor, .referenceVerifier, .alignmentAuditor]
        case .created, .finished: []
        }
    }
    static func prompt(_ state: ResearchSnapshot, role: Role) throws -> String {
        let session = state.autonomy!
        let contract = String(decoding: try Codec.encode(state.contract), as: UTF8.self)
        let hypotheses = String(decoding: try Codec.encode(state.hypotheses), as: UTF8.self)
        let runs = String(decoding: try Codec.encode(state.runs), as: UTF8.self)
        // Complete success/failure index is included; detailed recent role responses include source code.
        let history = session.history.map { "\($0.id) \($0.role.rawValue) \($0.proposal.decision) \($0.proposal.summary.prefix(800))" }.joined(separator: "\n")
        let recent = String(decoding: try Codec.encode(Array(session.history.suffix(4))), as: UTF8.self)
        let programs = String(decoding: try Codec.encode(session.history.filter { $0.proposal.experiment != nil }), as: UTF8.self)
        return """
        执行当前研究角色：\(role.rawValue)。阶段：\(state.phase.rawValue)。当前候选：\(session.currentCandidate?.uuidString ?? "尚未选择")。
        当前具体任务：\(assignment(role))
        必须基于已提供的真实运行结果，不得把方案、示例或预期写成已执行结果。
        \(session.knownProblem ? "本课题是已知问题的端到端验证，不要求创新性，也不得虚构创新、文献检索或引用；可不引用外部文献。" : "本课题要求科研贡献。创新性检查需要至少两条可核查参考依据；证据不足应返回 reject 或 no_candidate，不能声称已经完成检索。")
        运行范围：本机 CPU，单个实验最多 5 条输入、1 个批次、固定随机种子 0，不训练，不下载，不联网。所谓完整实验仅指覆盖本次已授权的微型数据，不得推广到完整真实数据集。
        实验程序必须定义 run(data)，返回 1–20 个有限数值的指标字典。仅允许 math、statistics、random 标准库与基础 Python 计算；不可调用 print/open/exec/eval，不可读取目录、运行外部程序或使用第三方库。输入 data 必须是 1–5 条的 JSON 数组。每个实验都会由服务实际运行并再运行一次复现；模型本身不能声称执行。
        可用内置函数仅包括 abs/all/any/bool/dict/enumerate/float/int/len/list/map/max/min/pow/range/reversed/round/set/sorted/str/sum/tuple/zip，以及 Exception/ValueError/ArithmeticError。不要使用 type、isinstance、getattr、hasattr 或以下划线开头的变量和属性。输入结构已由服务验证，可直接使用 data，无需重复类型检查。
        仅实验实现/修订角色返回 experiment，其他角色不得返回。baseline 提供基线，subset/fullSet 按当前候选实现；ablation 通过移除/替换关键机制检验贡献，rebuttal 根据实际评审提出补充实验。失败时依据运行日志修订，不复用失败指标。
        输出只能是一个 JSON 对象，不加 Markdown 围栏。summary 和所有自然语言内容必须中文。结构：
        {"summary":"中文证据与判断", "decision":"continue|good|engineer|bad|accept|reject|no_candidate", "hypotheses":null, "experiment":null, "manuscript":null, "score":null, "empiricalObjections":false, "candidateID":null, "evidenceIDs":[], "references":[]}
        可选 hypotheses 仅种子/演化角色使用，生成 2 个或以上候选，每项完整结构 {"id":"有效 UUID", "title":"中文", "mechanism":"中文可检验机制", "parentIDs":[], "evolved":false, "status":"untested", "noveltyReferences":[], "diagnostics":""}。
        外部文献引用必须增加 citations 数组，每项 {"doi":"10.xxxx/xxx", "title":"原文标题", "sourceHash":"已导入附件的资料校验值", "quote":"该附件中逐字摘录的支持段落", "claim":"该段落支持的中文论断"}。noveltyReferences 使用这些 DOI。referenceVerifier 必须列齐报告实际使用的引用，并令 claim 与报告中的相应表述一致；缺少附件原文时不能假称已核验支持关系。
        experiment 结构 {"question":"中文实验目的", "python":"def run(data): ...", "data":[...], "metric":"与程序输出一致的指标名"}。
        决策：验证通过用 accept；实验评价用 good/engineer/bad；没有有效候选用 no_candidate。selector 必须返回已有 fullGood 候选的 candidateID。peerReviewer 和 scoreVerifier 必须返回 0–10 的 score 与是否需补充实验 empiricalObjections。ablationCritic 只有实际消融支持机制归因才能 good；comparison 只有同协议证据支持严格改进才能 good。metaReviewer 审阅全流程后 accept/reject。
        writer/enhancer 返回完整中文 manuscript（不是摘要）；包含问题、方法、实际指标与数据规模、失败/限制、结论。必须在正文用完整 UUID 标注支撑结论的运行记录，并在 evidenceIDs 中列出。不得添加没有材料支持的引用、结果或创新声明。审计角色必须明确核对正文与已给代码、运行、规模的一致性。
        研究要求：\(contract)
        研究思路：\(hypotheses)
        实际运行记录：\(runs)
        完整成功/失败历史索引：\(history)
        最近步骤：\(recent)
        实际提交的实验代码和输入（通过代码内容 SHA-256 与运行记录对应）：\(programs)
        当前报告：\(state.manuscript)
        """
    }
    static func reproduced(_ runs: [ExperimentRun]) -> Bool {
        guard let first = runs.first(where: { $0.kind != .reproduction }), let second = runs.first(where: { $0.kind == .reproduction }),
              first.state == .succeeded, second.state == .succeeded, first.codeHash == second.codeHash,
              first.dataHash == second.dataHash, first.environmentFingerprint == second.environmentFingerprint,
              !first.metrics.isEmpty, Set(first.metrics.keys) == Set(second.metrics.keys) else { return false }
        return first.metrics.allSatisfy { key, value in abs(value - second.metrics[key]!) <= max(1e-10, abs(value) * 1e-8) }
    }
    static func reportCitationsValid(_ state: ResearchSnapshot, cited: Set<UUID>) -> Bool {
        let successful = Set(state.runs.filter { $0.state == .succeeded }.map(\.id))
        let resolved = Set(state.runs.filter { [.succeeded, .failed, .cancelled].contains($0.state) }.map(\.id))
        let roleRecords = Set(state.autonomy?.history.map(\.id) ?? [])
        return !state.manuscript.isEmpty && !cited.isDisjoint(with: successful)
            && cited.isSubset(of: resolved.union(roleRecords))
            && cited.allSatisfy { state.manuscript.lowercased().contains($0.uuidString.lowercased()) }
    }
}

extension ResearchService {
    func advanceAutonomous(_ initial: ResearchSnapshot, workflow: inout WorkflowState) async throws {
        var state = initial
        guard var session = state.autonomy else { throw NormaError.conflict }
        let previousPhase = workflow.phase
        let stage = session.history.suffix(AutonomousPolicy.roles(for: workflow).count)
        let last = stage.last?.proposal
        let phaseRuns = state.runs.filter { $0.planHash == state.plan?.hash }
        let reproduced = AutonomousPolicy.reproduced(phaseRuns)
        func acceptable(_ proposal: RoleProposal?) -> Bool { ["accept", "good", "continue"].contains(proposal?.decision ?? "") }
        func verdict() -> ExperimentVerdict {
            if !reproduced { return .engineer }
            return ExperimentVerdict(rawValue: last?.decision ?? "bad") ?? (acceptable(last) ? .good : .bad)
        }
        switch workflow.phase {
        case .limitations: try workflow.apply(.limitations(verified: acceptable(last)))
        case .seeds:
            let supported = session.knownProblem ? Set<String>() : try await verifyCitationClaims(state, claims: last?.citations ?? [], requireManuscript: false)
            state = try await store.snapshot(state.id)
            let verified = acceptable(last) && (session.knownProblem || state.hypotheses.allSatisfy {
                Set($0.noveltyReferences.map { $0.lowercased() }).count >= workflow.profile.noveltyReferences && Set($0.noveltyReferences.map { $0.lowercased() }).isSubset(of: supported)
            })
            try workflow.apply(.seeds(verifiedCount: verified ? state.hypotheses.count : 0))
        case .baseline:
            if reproduced { try workflow.apply(.baseline(reproduced: true)) }
            else { try workflow.apply(.baselineFailed) }
        case .subset:
            guard !phaseRuns.isEmpty else { throw NormaError.invalid("缺少初步实验记录。") }
            let decision = verdict()
            try workflow.apply(.subset(verdict: decision, evidence: true))
            if let index = state.hypotheses.firstIndex(where: { $0.id == session.currentCandidate }) {
                state.hypotheses[index].status = decision == .good ? .subsetGood : decision == .bad || workflow.phase != .subset ? .bad : .untested
                state.hypotheses[index].diagnostics = last?.summary ?? "实验失败"
            }
        case .fullSet:
            guard !phaseRuns.isEmpty else { throw NormaError.invalid("缺少完整实验记录。") }
            let decision = verdict()
            try workflow.apply(.fullSet(verdict: decision, evidence: true, compliant: decision == .engineer || reproduced))
            if let index = state.hypotheses.firstIndex(where: { $0.id == session.currentCandidate }) {
                state.hypotheses[index].status = decision == .good ? .fullGood : .bad
                state.hypotheses[index].diagnostics = last?.summary ?? "实验失败"
            }
        case .evolution:
            try workflow.apply(.nextRound(hasUntriedSeed: state.hypotheses.contains { !session.candidatesUsed.contains($0.id) }, evolvedFromCompleteHistory: true))
        case .selection:
            guard let candidate = last?.candidateID else { throw NormaError.invalid("未返回候选方案编号。") }
            try workflow.apply(.selection(candidateID: candidate, fullGoodIDs: Set(state.hypotheses.filter { $0.status == .fullGood }.map(\.id))))
            session.currentCandidate = candidate
        case .ablation:
            if session.knownProblem, reproduced {
                try workflow.apply(.knownProblemComparison(verified: true))
            } else {
                try workflow.apply(.ablation(attributable: reproduced && acceptable(last), needsRefinement: last?.decision == "engineer"))
            }
        case .refinement:
            let previous = state.runs.filter { $0.kind == .fullSet && $0.planHash != state.plan?.hash && $0.state == .succeeded }.last
            let current = phaseRuns.first { $0.kind != .reproduction }
            try workflow.apply(.comparison(improved: reproduced && last?.decision == "good",
                sameProtocol: previous?.dataHash == current?.dataHash && previous?.protocolHash == current?.protocolHash, evidence: reproduced))
        case .writing:
            let cited = Set(last?.evidenceIDs ?? [])
            guard AutonomousPolicy.reportCitationsValid(state, cited: cited) else { throw NormaError.invalid("报告缺少可追溯的实际运行引用。") }
            let report = try await artifacts.put(Data(state.manuscript.utf8), kind: .manuscript, researchID: state.id)
            _ = try await store.update(state, expected: state.revision, kind: "manuscript.saved", detail: report.hash, artifacts: [report])
            state = try await store.snapshot(state.id)
            try workflow.apply(.manuscript(evidenceComplete: true))
        case .peerReview:
            guard let score = last?.score else { throw NormaError.invalid("评审缺少有效评分。") }
            let empirical = stage.contains { $0.proposal.empiricalObjections == true }
            try workflow.apply(.peer(score: score, empiricalObjections: empirical))
        case .rebuttal: try workflow.apply(.rebuttal(experimentsComplete: reproduced))
        case .metaReview: try workflow.apply(.meta(accepted: last?.decision == "accept"))
        case .integrity:
            let citedRuns = Set(session.history.last(where: { $0.role == .enhancer || $0.role == .writer })?.proposal.evidenceIDs ?? [])
            let citedPlans = Set(state.runs.filter { citedRuns.contains($0.id) && $0.state == .succeeded }.map(\.planHash))
            let groups = Dictionary(grouping: state.runs.filter { citedPlans.contains($0.planHash) }, by: \.planHash)
            let reproductionPassed = !groups.isEmpty && groups.values.allSatisfy(AutonomousPolicy.reproduced)
            let objects = try await store.artifacts(state.id)
            var evidenceValid = true
            for object in objects { do { _ = try await artifacts.read(object, researchID: state.id) } catch { evidenceValid = false } }
            let reference = stage.first { $0.role == .referenceVerifier }?.proposal
            // Model judgment alone cannot verify external literature. Unverified citations block formal export.
            let noExternalClaims = session.knownProblem && session.history.allSatisfy { ($0.proposal.references ?? []).isEmpty && ($0.proposal.citations ?? []).isEmpty }
                && state.hypotheses.allSatisfy { $0.noveltyReferences.isEmpty } && reference?.decision == "accept"
                && !state.manuscript.contains("https://") && state.manuscript.range(of: "10\\.\\d{4,9}/", options: .regularExpression) == nil
            let cited = try await verifyCitationClaims(state, claims: reference?.citations ?? [], requireManuscript: true)
            state = try await store.snapshot(state.id)
            let expected = Set((reference?.references ?? []).map { $0.lowercased() })
            let referencesPassed = noExternalClaims || (reference?.decision == "accept" && !expected.isEmpty && expected == cited)
            state.integrity = [Check("I1", reproductionPassed ? .pass : .fail, "逐项核对本轮实验与实际复现的指标"),
                Check("I2", evidenceValid && stage.first(where: { $0.role == .specificationAuditor })?.proposal.decision == "accept" ? .pass : .fail, "核对冻结输入、运行依据与授权范围"),
                Check("I3", referencesPassed ? .pass : .unknown, noExternalClaims ? "已知问题验证，不包含外部文献或创新性声明" : referencesPassed ? "DOI 与标题已核实，引用摘录存在于已保存原文，独立角色已核对论断支持关系" : "外部文献对论断的支持尚未完成独立核实"),
                Check("I4", evidenceValid && last?.decision == "accept" ? .pass : .fail, "独立角色核对中文报告与实验实现及实际运行")]
            if !state.integrity.allSatisfy({ $0.status == .pass }), reproductionPassed, evidenceValid,
               (workflow.reportRevisions ?? 0) < 1, !stage.contains(where: { $0.proposal.empiricalObjections == true }) {
                try workflow.apply(.integrityReportRevision(evidenceIntact: true))
            } else {
                try workflow.apply(.integrity(state.integrity))
            }
        case .created, .finished: throw NormaError.invalid("自主流程阶段无效。")
        }
        // Advance to an unused candidate only after the previous one has finished evaluation.
        if workflow.phase == .subset && (previousPhase != .subset || workflow.engineeringAttempts == 0) {
            if let next = state.hypotheses.first(where: { !session.candidatesUsed.contains($0.id) }) {
                session.currentCandidate = next.id; session.candidatesUsed.append(next.id)
            } else { throw NormaError.invalid("没有尚未验证的候选方案。") }
        }
        session.workflow = try Codec.encode(workflow); session.roleIndex = 0; session.stepID = nil
        state.autonomy = session; state.phase = workflow.phase; state.outcome = workflow.outcome; state.metaAccepted = workflow.metaAccepted
        if workflow.phase == .finished { state.operation = .succeeded }
        _ = try await store.update(state, expected: state.revision, kind: "phase.completed", detail: previousPhase.rawValue)
    }

    private func verifyCitationClaims(_ initial: ResearchSnapshot, claims: [CitationClaim], requireManuscript: Bool) async throws -> Set<String> {
        guard claims.count <= 8 else { throw NormaError.invalid("单次引用核查最多 8 条。") }
        var supported = Set<String>()
        for claim in claims {
            guard !claim.claim.isEmpty, claim.quote.count >= 20, claim.quote.count <= 4000,
                  let source = initial.sources?.first(where: { $0.artifact?.hash == claim.sourceHash }), let artifact = source.artifact else { continue }
            let text = ResearchContextReader.extract(try await artifacts.read(artifact, researchID: initial.id), name: source.name)
            func normalize(_ value: String) -> String { value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
            guard normalize(text).contains(normalize(claim.quote)), !requireManuscript || initial.manuscript.contains(claim.claim) else { continue }
            do {
                var receipt = try await ReferenceVerifier().verify(doi: claim.doi, expectedTitle: claim.title)
                guard receipt.existence == .pass else { continue }
                // Semantic support is the independent reviewer's judgment, tied to a verified literal source excerpt.
                receipt.claimSupport = .pass
                let evidence = try await artifacts.put(Codec.encode(receipt), kind: .citation, researchID: initial.id)
                let state = try await store.snapshot(initial.id)
                _ = try await store.update(state, expected: state.revision, kind: "reference.checked", detail: claim.doi, artifacts: [evidence],
                    edges: [EvidenceEdge(sourceHash: evidence.hash, targetHash: artifact.hash, relation: "quotedFrom")])
                supported.insert(claim.doi.lowercased())
            } catch { continue }
        }
        return supported
    }
}
