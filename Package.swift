// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "NORMA", platforms: [.macOS(.v14)],
    products: ["ResearchContracts", "ResearchKernel", "NORMAClient", "NORMAUI"].map { .library(name: $0, targets: [$0]) } + [.executable(name: "NORMAResearchService", targets: ["NORMAResearchService"]), .executable(name: "NORMA", targets: ["NORMAApp"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0")],
    targets: [
        .target(name: "ResearchContracts", path: "packages/ResearchContracts"),
        .target(name: "CodexBridge", dependencies: ["ResearchContracts"], path: "packages/CodexBridge"),
        .target(name: "AuthCoordinator", dependencies: ["CodexBridge"], path: "packages/AuthCoordinator"),
        .target(name: "AgentRuntime", dependencies: ["CodexBridge"], path: "packages/AgentRuntime"),
        .target(name: "ResearchStore", dependencies: ["ResearchContracts", .product(name: "GRDB", package: "GRDB.swift")], path: "packages/ResearchStore"),
        .target(name: "EvidenceEngine", dependencies: ["ResearchContracts"], path: "packages/EvidenceEngine"),
        .target(name: "ComputeController", dependencies: ["ResearchContracts"], path: "packages/ComputeController"),
        .target(name: "ExperimentManager", dependencies: ["ComputeController", "EvidenceEngine"], path: "packages/ExperimentManager"),
        .target(name: "ReviewEngine", dependencies: ["ResearchContracts"], path: "packages/ReviewEngine"),
        .target(name: "ResearchKernel", dependencies: ["ResearchStore", "AgentRuntime", "AuthCoordinator", "ExperimentManager", "ReviewEngine"], path: "packages/ResearchKernel"),
        .target(name: "NORMAClient", dependencies: ["ResearchContracts"], path: "packages/NORMAClient"),
        .target(name: "NORMAUI", dependencies: ["NORMAClient"], path: "packages/NORMAUI"),
        .executableTarget(name: "NORMAApp", dependencies: ["NORMAUI"], path: "apps/NORMAApp", exclude: ["app.norma.research.plist"]),
        .executableTarget(name: "NORMAResearchService", dependencies: ["ResearchKernel"], path: "apps/NORMAResearchService"),
        .testTarget(name: "NORMATests", dependencies: ["ResearchKernel", "NORMAClient", "NORMAUI"], path: "tests/unit")
    ], swiftLanguageModes: [.v6]
)
