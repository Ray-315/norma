import Foundation
import ResearchContracts

public enum EvidenceValidator {
    public static func file(path: String, expectedHash: String, allowedRoot: URL) throws {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let root = allowedRoot.resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(root) else { throw NormaError.forbidden("Artifact outside research root") }
        guard Codec.hash(try Data(contentsOf: url)) == expectedHash else { throw NormaError.invalid("Evidence hash mismatch") }
    }
    public static func smoke(original: ExperimentRun, reproduction: ExperimentRun) -> [Check] {
        let values = ["slope", "intercept", "mse"]
        let reproduced = original.state == .succeeded && reproduction.state == .succeeded && values.allSatisfy {
            guard let a = original.metrics[$0], let b = reproduction.metrics[$0] else { return false }
            return a.isFinite && b.isFinite && abs(a - b) <= 1e-12
        }
        let known = abs((original.metrics["slope"] ?? .infinity) - 2) <= 1e-12 &&
            abs((original.metrics["intercept"] ?? .infinity) - 1) <= 1e-12
        return [
            Check("I1", reproduced && known ? .pass : .fail, "Independent covariance rerun versus normal equations and analytic line y=2x+1"),
            Check("I2", original.dataHash == reproduction.dataHash && original.protocolHash == reproduction.protocolHash ? .pass : .fail, "Fixed five points; one batch, one seed, zero training steps"),
            Check("I3", .unknown, "No research manuscript or literature claims in numerical smoke"),
            Check("I4", .unknown, "Numerical smoke is not a manuscript/code alignment audit")
        ]
    }
}
