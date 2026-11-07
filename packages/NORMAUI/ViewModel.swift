import Foundation
import AppKit
import Observation
import ResearchContracts
import NORMAClient

public enum Page: String, CaseIterable, Identifiable, Sendable {
    case overview = "总览", workspace = "研究概况", hypotheses = "研究思路", experiments = "实验结果",
         execution = "准备与执行", reviews = "评审与核查", compute = "算力", artifacts = "研究文件", settings = "设置"
    static let primary: [Page] = [.overview, .workspace, .compute, .settings]
    static let research: [Page] = [.workspace, .execution, .experiments, .hypotheses, .reviews, .artifacts]
    var isResearch: Bool { Self.research.contains(self) }
    var navigationTitle: String { self == .workspace ? "课题工作台" : rawValue }
    public var id: Self { self }
    var icon: String {
        switch self { case .overview: "square.grid.2x2"; case .workspace: "atom"; case .hypotheses: "point.3.connected.trianglepath.dotted"
        case .experiments: "flask"; case .execution: "checkmark.shield"; case .reviews: "doc.text.magnifyingglass"
        case .compute: "server.rack"; case .artifacts: "books.vertical"; case .settings: "gearshape" }
    }
}
@MainActor @Observable public final class AppModel {
    public var page: Page = .overview; public var selectedID: UUID?
    public var researches: [ResearchSnapshot] = []; public var error: String?; public var busy = false
    public var account: AccountStatus?; public var models: [ModelDescriptor] = []
    public var selectedProfile = "chatgpt"
    public var environment: EnvironmentSnapshot?; public var node: ComputeNode?
    public var showInspector = false; public var showWelcome = false
    public let client: any ResearchClientProtocol; public let demo: Bool
    public var current: ResearchSnapshot? { researches.first { $0.id == selectedID } }
    public init(client: any ResearchClientProtocol = XPCResearchClient(), demo: Bool = false) { self.client = client; self.demo = demo }
    public func refresh() async {
        do {
            researches = try await client.call("research.list", Empty(), as: [ResearchSnapshot].self)
            if selectedID == nil { selectedID = researches.first?.id }
        } catch { self.error = DisplayText.error(error) }
    }
    public func action(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        Task { defer { busy = false }; do { try await operation(); await refresh() } catch { self.error = DisplayText.error(error) } }
    }
    public func command(_ method: String) {
        guard let state = current else { return }
        action {
            let response = try await self.client.send(IPCRequest(method: method, value: ResearchCommand(id: state.id, revision: state.revision)))
            if let error = response.error { throw error }
        }
    }
    public func create(title: String, question: String, metric: String) {
        action {
            let contract = ResearchContract(title: title, question: question, metric: metric)
            self.selectedID = try await self.client.call("research.create", contract, as: UUID.self); self.page = .workspace
        }
    }
    public func discover() {
        action {
            self.node = try await self.client.call("target.local", Empty(), as: ComputeNode.self)
            self.environment = try await self.client.call("environment.local", Empty(), as: EnvironmentSnapshot.self)
        }
    }
    public func checkAccount() {
        action { self.account = try await self.client.call("account.status", self.selectedProfile, as: AccountStatus.self) }
    }
    public func login() {
        action {
            let url = try await self.client.call("account.login", Empty(), as: String.self)
            guard let address = URL(string: url), address.scheme == "https", address.host == "auth.openai.com" else { throw NormaError.invalid("Invalid login URL") }
            NSWorkspace.shared.open(address)
            self.selectedProfile = "chatgpt"
        }
    }
    public func loadModels() {
        action { self.models = try await self.client.call("model.list", self.selectedProfile, as: [ModelDescriptor].self) }
    }
    public func loginAPI(_ key: String) {
        action {
            self.account = try await self.client.call("account.apiLogin", key, as: AccountStatus.self)
            self.selectedProfile = "api"; self.models = []
        }
    }
    public func authorizeSmoke() {
        guard let state = current, let report = state.preflight else { return }
        action {
            let node = try await self.client.call("target.local", Empty(), as: ComputeNode.self)
            let auth = ResearchAuthorization(researchID: state.id, contractVersion: state.contract.version, target: node,
                fingerprint: report.environmentFingerprint, expiresAt: Date().addingTimeInterval(3600),
                maxModelCalls: 0, maxRuns: 2, maxRuntimeSeconds: 30)
            _ = try await self.client.call("target.authorize", AuthorizeCommand(revision: state.revision, authorization: auth), as: ResearchSnapshot.self)
        }
    }
    public func selectLocal() {
        guard let state = current else { return }
        action {
            self.node = try await self.client.call("target.local", Empty(), as: ComputeNode.self)
            _ = try await self.client.call("target.selectLocal", ResearchCommand(id: state.id, revision: state.revision), as: ResearchSnapshot.self)
        }
    }
    public func revise(title: String, question: String, metric: String, constraints: String) {
        guard let state = current else { return }
        action {
            var contract = state.contract
            contract.version += 1; contract.title = title; contract.question = question
            contract.metric = metric; contract.constraints = constraints
            _ = try await self.client.call("contract.revise", ReviseCommand(contract: contract, revision: state.revision), as: ResearchSnapshot.self)
        }
    }
    public func chooseSources(project: Bool) {
        guard let state = current else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = project; panel.canChooseFiles = !project
        panel.allowsMultipleSelection = !project
        panel.prompt = project ? "选择项目文件夹" : "添加附件"
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        action {
            _ = try await self.client.call("sources.import", SourceImportCommand(id: state.id, revision: state.revision, paths: paths, project: project), as: ResearchSnapshot.self)
        }
    }
    public func removeSource(_ sourceID: UUID) {
        guard let state = current else { return }
        action {
            _ = try await self.client.call("sources.remove", SourceRemoveCommand(id: state.id, revision: state.revision, sourceID: sourceID), as: ResearchSnapshot.self)
        }
    }
    public func backup() {
        action {
            let path = try await self.client.call("storage.backup", Empty(), as: String.self)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }
    public func exportResearch() {
        guard let state = current else { return }
        action {
            let confirmed = try await self.client.call("export.confirm", ResearchCommand(id: state.id, revision: state.revision), as: ResearchSnapshot.self)
            let path = try await self.client.call("export.bundle", ResearchCommand(id: state.id, revision: confirmed.revision), as: String.self)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }
}
