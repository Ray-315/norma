import Foundation
public enum TargetKind: String, Codable, CaseIterable, Sendable { case local, lab, external }
public struct ComputeNode: Codable, Sendable, Identifiable, Equatable {
    public var id: String; public var name: String; public var kind: TargetKind
    public var host: String?; public var port: Int?; public var user: String?
    public var workDirectory: String; public var python: String; public var hostFingerprint: String?
    public init(id: String, name: String, kind: TargetKind, workDirectory: String, python: String) {
        self.id = id; self.name = name; self.kind = kind; self.workDirectory = workDirectory; self.python = python
    }
}
public struct EnvironmentSnapshot: Codable, Sendable, Equatable {
    public var nodeID: String; public var python: String; public var version: String
    public var architecture: String; public var platform: String; public var capturedAt: Date
    public var fingerprint: String; public var freeBytes: Int64
    public var dependencyFingerprint: String
    public init(nodeID: String, python: String, version: String, architecture: String, platform: String, freeBytes: Int64, dependencyFingerprint: String = "") {
        self.nodeID = nodeID; self.python = python; self.version = version; self.architecture = architecture
        self.platform = platform; self.freeBytes = freeBytes; capturedAt = Date()
        self.dependencyFingerprint = dependencyFingerprint
        fingerprint = Codec.hash(Data([nodeID, python, version, architecture, platform, dependencyFingerprint].joined(separator: "|").utf8))
    }
}
public struct ResearchAuthorization: Codable, Sendable, Identifiable {
    public var id = UUID(); public var researchID: UUID; public var contractVersion: Int
    public var target: ComputeNode; public var environmentFingerprint: String; public var approvedAt = Date()
    public var expiresAt: Date; public var maxModelCalls: Int; public var maxRuns: Int; public var maxRuntimeSeconds: Int
    public var profileID: String; public var model: String; public var reasoning: String; public var revoked = false
    public var usedRuns: Int?
    public var usedModelCalls: Int?
    public init(researchID: UUID, contractVersion: Int, target: ComputeNode, fingerprint: String, expiresAt: Date,
                maxModelCalls: Int, maxRuns: Int, maxRuntimeSeconds: Int, profileID: String = "chatgpt",
                model: String = "gpt-6.1-sol", reasoning: String = "medium") {
        self.researchID = researchID; self.contractVersion = contractVersion; self.target = target
        environmentFingerprint = fingerprint; self.expiresAt = expiresAt; self.maxModelCalls = maxModelCalls
        self.maxRuns = maxRuns; self.maxRuntimeSeconds = maxRuntimeSeconds; self.profileID = profileID
        self.model = model; self.reasoning = reasoning
    }
}
public enum ExperimentKind: String, Codable, CaseIterable, Sendable { case baseline, subset, fullSet, ablation, rebuttal, reproduction }
public struct ExperimentPlan: Codable, Sendable, Identifiable {
    public var id = UUID(); public var researchID: UUID; public var contractVersion: Int
    public var kind: ExperimentKind; public var question: String; public var datasetHash: String
    public var codeHash: String; public var protocolHash: String; public var runtimeSeconds: Int
    public var frozen = false
    public var hash: String { (try? Codec.digest(self)) ?? "" }
    public init(researchID: UUID, contractVersion: Int, kind: ExperimentKind, question: String, datasetHash: String, codeHash: String, protocolHash: String, runtimeSeconds: Int) {
        self.researchID = researchID; self.contractVersion = contractVersion; self.kind = kind; self.question = question
        self.datasetHash = datasetHash; self.codeHash = codeHash; self.protocolHash = protocolHash; self.runtimeSeconds = runtimeSeconds
    }
}
public struct ExecutionTargetSelection: Codable, Sendable { public var planID: UUID; public var targetID: String; public var authorizationID: UUID }
public enum CheckStatus: String, Codable, Sendable { case pass, fail, unknown }
public struct Check: Codable, Sendable, Identifiable {
    public var id: String; public var status: CheckStatus; public var detail: String
    public init(_ id: String, _ status: CheckStatus, _ detail: String) { self.id = id; self.status = status; self.detail = detail }
}
public struct TargetPreflightReport: Codable, Sendable, Identifiable {
    public var id = UUID(); public var planHash: String; public var targetID: String; public var environmentFingerprint: String
    public var validUntil: Date; public var checks: [Check]
    public var passed: Bool { !checks.isEmpty && checks.allSatisfy { $0.status == .pass } }
    public init(planHash: String, targetID: String, fingerprint: String, checks: [Check], now: Date = Date()) {
        self.planHash = planHash; self.targetID = targetID; environmentFingerprint = fingerprint
        self.checks = checks; validUntil = now.addingTimeInterval(300)
    }
}
public struct ExecutionAuthorization: Codable, Sendable, Identifiable {
    public var id = UUID(); public var parentID: UUID; public var planHash: String; public var targetID: String
    public var reportID: UUID; public var expiresAt: Date
}
public struct ExecutionDispatch: Codable, Sendable, Identifiable {
    public var id = UUID(); public var researchID: UUID; public var plan: ExperimentPlan
    public var authorizationID: UUID; public var targetID: String; public var idempotencyKey: String; public var state: OperationState = .queued
}
