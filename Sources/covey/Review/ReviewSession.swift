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

/// What Review needs from the app: which sessions it may send
/// to, and a way to write bytes into one. `AppModel` is the production one.
@MainActor
protocol ReviewSessionDirectory: AnyObject {
    func reviewTargets(projectRoot: String) -> [ReviewTarget]
    func sendToSession(_ name: String, bytes: [UInt8]) async throws
}

private let knownShells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "nu"]

/// The program name of an `agent` string: its first whitespace-separated
/// token (custom agents keep their flags there), that token's basename, and
/// one leading `-` removed (a login shell is launched as `-zsh`).
private func programName(_ agent: String) -> String? {
    guard let token = agent.split(whereSeparator: \.isWhitespace).first else { return nil }
    var name = (String(token) as NSString).lastPathComponent
    if name.hasPrefix("-") { name.removeFirst() }
    return name.isEmpty ? nil : name
}

/// Terminal sessions carry the shell's basename as `agent`
/// (`composeLaunch` → label), and a custom agent may be a shell with flags.
/// Pasting a prompt and pressing Enter there would run it as commands, so
/// they are never targets.
func isShellAgent(_ agent: String, shell: String? = ProcessInfo.processInfo.environment["SHELL"]) -> Bool {
    guard let name = programName(agent) else { return false }
    if knownShells.contains(name) { return true }
    if let shell, programName(shell) == name { return true }
    return false
}
