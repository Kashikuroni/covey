import Foundation
import CoveyKit
@testable import covey

struct FakeSendError: Error, CustomStringConvertible {
    var description: String { "session is gone" }
}

/// Records every write; throws `failure` (once set) instead of recording.
@MainActor
final class FakeDirectory: ReviewSessionDirectory {
    var targets: [ReviewTarget] = []
    var sent: [(name: String, bytes: [UInt8])] = []
    var failure: Error?

    func reviewTargets(projectRoot: String) -> [ReviewTarget] { targets }

    func sendToSession(_ name: String, bytes: [UInt8]) async throws {
        if let failure { throw failure }
        sent.append((name, bytes))
    }
}
