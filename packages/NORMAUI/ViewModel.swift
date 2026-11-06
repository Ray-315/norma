import Foundation
import AppKit
import Observation
import ResearchContracts
import NORMAClient

public enum Page: String, CaseIterable, Identifiable {
    case overview = "总览", workspace = "研究工作区", hypotheses = "假设树", experiments = "实验",
         execution = "执行门禁", reviews = "评审与完整性", compute = "算力", artifacts = "文献与产物", settings = "设置"
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
    public var showInspector = true; public var showWelcome = false
    public let client: any ResearchClientProtocol; public let demo: Bool
    public var current: ResearchSnapshot? { researches.first { $0.id == selectedID } }
    public init(client: any ResearchClientProtocol = XPCResearchClient(), demo: Bool = false) { self.client = client; self.demo = demo }
    public func refresh() async {
        do {
            researches = try await client.call("research.list", Empty(), as: [ResearchSnapshot].self)
            if selectedID == nil { selectedID = researches.first?.id }
        } catch { self.error = error.localizedDescription }
    }
    public func action(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        Task { defer { busy = false }; do { try await operation(); await refresh() } catch { self.error = error.localizedDescription } }
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
