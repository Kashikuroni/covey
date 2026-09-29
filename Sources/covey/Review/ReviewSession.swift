import Foundation
import CoveyKit

/// A session the review can be sent to.
struct ReviewTarget: Equatable, Identifiable {
    var id: String { name }
    let name: String
    let dir: String
    let agent: String
    let status: Status
}

/// What the Review window needs from the app: which sessions it may send
/// to, and a way to write bytes into one. `AppModel` is the production one.
@MainActor
protocol ReviewSessionDirectory: AnyObject {
    func reviewTargets(projectRoot: String) -> [ReviewTarget]
    func sendToSession(_ name: String, bytes: [UInt8]) async throws
}

private let knownShells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "nu"]

/// Terminal sessions carry the shell's basename as `agent`
/// (`composeLaunch` → label). Pasting a prompt and pressing Enter there would
/// run it as commands, so they are never targets.
func isShellAgent(_ agent: String, shell: String? = ProcessInfo.processInfo.environment["SHELL"]) -> Bool {
    let name = (agent as NSString).lastPathComponent
    if knownShells.contains(name) { return true }
    if let shell, (shell as NSString).lastPathComponent == name { return true }
    return false
}
