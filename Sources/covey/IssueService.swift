import Foundation
import CoveyKit

/// The new issue's URL from `gh issue create` stdout: gh prints it as the
/// last line (progress chatter may precede it). Nil when there is none.
func parseIssueURL(_ stdout: String) -> String? {
    stdout.split(separator: "\n").map {
        $0.trimmingCharacters(in: .whitespaces)
    }.last { !$0.isEmpty }
}

/// The gh invocation for a new issue; pure so tests pin the flag layout.
func issueCreateArgs(title: String, body: String, assignMe: Bool,
                     labels: [String], web: Bool) -> [String] {
    var args = ["gh", "issue", "create", "--title", title, "--body", body]
    if assignMe { args += ["--assignee", "@me"] }
    for label in labels { args += ["--label", label] }
    if web { args.append("--web") }
    return args
}

/// JSON fields the browser needs; bodies come with the list so the
/// detail screen needs no second call.
let issueListFields =
    "number,title,body,state,author,labels,updatedAt,url,closedByPullRequestsReferences"

/// gh invocations for the issue browser; pure so tests pin flag layout.
func issueListArgs(state: IssueState, limit: Int = 100) -> [String] {
    ["gh", "issue", "list", "--json", issueListFields,
     "--state", state.rawValue, "--limit", String(limit)]
}

func issueEditArgs(number: Int, title: String?, body: String?,
                   addLabels: [String], removeLabels: [String]) -> [String] {
    var args = ["gh", "issue", "edit", String(number)]
    if let title { args += ["--title", title] }
    if let body { args += ["--body", body] }
    for l in addLabels { args += ["--add-label", l] }
    for l in removeLabels { args += ["--remove-label", l] }
    return args
}

func issueCloseArgs(number: Int, reason: CloseReason) -> [String] {
    ["gh", "issue", "close", String(number), "--reason", reason.rawValue]
}

func issueReopenArgs(number: Int) -> [String] {
    ["gh", "issue", "reopen", String(number)]
}

func issueDeleteArgs(number: Int) -> [String] {
    ["gh", "issue", "delete", String(number), "--yes"]
}

func labelListArgs() -> [String] {
    ["gh", "label", "list", "--json", "name,color"]
}

/// Terminal outcome of a gh call. A dedicated type because `Result`'s
/// failure must be an `Error` (a bare `String` is not).
enum IssueOutcome: Equatable {
    case success(url: String)
    case failure(message: String)
}

let ghNotFoundMessage =
    "gh CLI not found — install it (brew install gh), then `gh auth login`"

/// A finished gh process. nil from runGh = the spawn itself failed.
struct GhRun {
    var status: Int32
    var stdout: Data
    var stderr: Data
}

/// Child environment for gh: the inherited env with the user-level bin
/// dirs appended to PATH — a Finder-spawned GUI gets the bare system
/// PATH, where Homebrew's gh doesn't resolve (env exits 127).
func ghEnvironment(base: [String: String], home: String) -> [String: String] {
    var env = base
    env["PATH"] = enrichedPATH(base["PATH"], home: home)
    return env
}

/// Spawns `/usr/bin/env <args>` in `dir` off the main thread and waits.
/// Arguments go straight to the process — nothing passes through a shell.
func runGh(args: [String], dir: String) async -> GhRun? {
    await Task.detached {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.environment = ghEnvironment(base: ProcessInfo.processInfo.environment,
                                      home: NSHomeDirectory())
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return nil }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return GhRun(status: p.terminationStatus, stdout: stdout, stderr: stderr)
    }.value
}

/// gh call result for the browser; failure carries a display-ready message.
enum GhOutcome<T: Equatable>: Equatable {
    case success(T)
    case failure(String)
}

/// Files a GitHub issue with the `gh` CLI (port of git.rs
/// spawn_issue_create). A network call — always awaited off the UI.
enum IssueService {
    /// .success = the created issue's URL (or gh's confirmation for --web);
    /// .failure = a display-ready error.
    static func create(dir: String, title: String, body: String,
                       assignMe: Bool = false, labels: [String] = [],
                       web: Bool = false) async -> IssueOutcome {
        let args = issueCreateArgs(title: title, body: body, assignMe: assignMe,
                                   labels: labels, web: web)
        guard let run = await runGh(args: args, dir: dir), run.status != 127 else {
            return .failure(message: ghNotFoundMessage)
        }
        guard run.status == 0 else {
            let msg = String(decoding: run.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(message: msg.isEmpty ? "gh issue create failed" : msg)
        }
        if web { return .success(url: "") }
        guard let url = parseIssueURL(String(decoding: run.stdout, as: UTF8.self)) else {
            return .failure(message: "issue created, but gh printed no URL — check GitHub")
        }
        return .success(url: url)
    }

    private static func failureMessage(_ run: GhRun?, fallback: String) -> String {
        guard let run else { return ghNotFoundMessage }
        if run.status == 127 { return ghNotFoundMessage }
        let msg = String(decoding: run.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.isEmpty ? fallback : msg
    }

    static func list(dir: String, state: IssueState) async -> GhOutcome<[GhIssue]> {
        let run = await runGh(args: issueListArgs(state: state), dir: dir)
        guard let run, run.status == 0 else {
            return .failure(failureMessage(run, fallback: "gh issue list failed"))
        }
        guard let issues = parseIssues(run.stdout) else {
            return .failure("gh returned unreadable issue JSON")
        }
        return .success(issues)
    }

    static func labelList(dir: String) async -> GhOutcome<[GhLabel]> {
        let run = await runGh(args: labelListArgs(), dir: dir)
        guard let run, run.status == 0 else {
            return .failure(failureMessage(run, fallback: "gh label list failed"))
        }
        guard let labels = parseLabels(run.stdout) else {
            return .failure("gh returned unreadable label JSON")
        }
        return .success(labels)
    }

    /// Edit/close/reopen/delete: nil = success, otherwise a display message.
    static func mutate(args: [String], dir: String) async -> String? {
        let run = await runGh(args: args, dir: dir)
        guard let run, run.status == 0 else {
            return failureMessage(run, fallback: "gh command failed")
        }
        return nil
    }
}
