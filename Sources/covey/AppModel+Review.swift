import Foundation
import CoveyKit

extension AppModel: ReviewSessionDirectory {
    func reviewTargets(projectRoot: String) -> [ReviewTarget] {
        visibleSessions
            .filter { sessionRoot($0) == projectRoot && !isShellAgent($0.agent) }
            .map { ReviewTarget(name: $0.name, dir: $0.dir, agent: $0.agent,
                                status: statusByName[$0.name] ?? .idle) }
    }

    func sendToSession(_ name: String, bytes: [UInt8]) async throws {
        try await client.input(name: name, bytes: bytes)
    }
}
