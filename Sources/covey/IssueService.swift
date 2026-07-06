import Foundation

/// The new issue's URL from `gh issue create` stdout: gh prints it as the
/// last line (progress chatter may precede it). Nil when there is none.
func parseIssueURL(_ stdout: String) -> String? {
    stdout.split(separator: "\n").map {
        $0.trimmingCharacters(in: .whitespaces)
    }.last { !$0.isEmpty }
}

/// Terminal outcome of a gh call. A dedicated type because `Result`'s
/// failure must be an `Error` (a bare `String` is not).
enum IssueOutcome: Equatable {
    case success(url: String)
    case failure(message: String)
}

/// Files a GitHub issue with the `gh` CLI (port of git.rs
/// spawn_issue_create). A network call — always awaited off the UI.
enum IssueService {
    /// .success = the created issue's URL; .failure = a display-ready error.
    static func create(dir: String, title: String, body: String) async -> IssueOutcome {
        await Task.detached {
            let notFound = "gh CLI not found — install it (brew install gh), then `gh auth login`"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            // Arguments go straight to gh — nothing passes through a shell.
            p.arguments = ["gh", "issue", "create", "--title", title, "--body", body]
            p.currentDirectoryURL = URL(fileURLWithPath: dir)
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch {
                return .failure(message: notFound)
            }
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            // env exits 127 when gh itself is missing.
            if p.terminationStatus == 127 { return .failure(message: notFound) }
            guard p.terminationStatus == 0 else {
                let msg = String(decoding: stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(message: msg.isEmpty ? "gh issue create failed" : msg)
            }
            guard let url = parseIssueURL(String(decoding: stdout, as: UTF8.self)) else {
                return .failure(message: "issue created, but gh printed no URL — check GitHub")
            }
            return .success(url: url)
        }.value
    }
}
