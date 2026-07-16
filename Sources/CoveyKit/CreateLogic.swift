import Foundation

/// Pure session-creation logic shared by the daemon (command assembly) and the
/// GUI (form preview, effort tables). Port of amux-core create.rs; the IO
/// orchestration lives daemon-side in CreateService.

/// Worktree parameters when the chosen branch requires one.
public enum WorktreeSpec: Codable, Equatable {
    /// Fork a new branch from `base` (the "+ create" picker entry).
    case new(branch: String, base: String)
    /// Check out an existing branch — reuse its worktree or add one.
    case existing(branch: String)
    /// Switch to an existing branch in the repo root, no worktree —
    /// unless the branch already has one, which the session then opens.
    case checkout(branch: String)
    /// Create `branch` from `base` in the repo root and switch to it.
    case checkoutNew(branch: String, base: String)
}

/// Everything needed to create one session. `dir` must be absolute and
/// tilde-expanded. `model`/`effort` apply to claude only.
public struct CreateSpec: Equatable {
    public var name: String?
    public var dir: String
    public var agent: String
    public var terminal: Bool
    public var worktree: WorktreeSpec?
    public var model: String?
    public var effort: String?
    /// Relaunch: a saved "claude --resume <uuid>" command to run verbatim.
    public var resume: String?

    public init(name: String? = nil, dir: String, agent: String,
                terminal: Bool = false, worktree: WorktreeSpec? = nil,
                model: String? = nil, effort: String? = nil, resume: String? = nil) {
        self.name = name; self.dir = dir; self.agent = agent
        self.terminal = terminal; self.worktree = worktree
        self.model = model; self.effort = effort; self.resume = resume
    }
}

/// Claude model aliases (aliases, not full names, so claude resolves them).
public let claudeModels = ["opus", "sonnet", "haiku"]

/// Effort slider positions per model; "auto" emits no --effort flag.
/// Sonnet has no xhigh; haiku does not support effort at all.
public func effortLevels(model: String?) -> [String] {
    switch model {
    case "opus": return ["auto", "low", "medium", "high", "xhigh", "max"]
    case "sonnet": return ["auto", "low", "medium", "high", "max"]
    default: return ["auto"]
    }
}

/// The final command a create runs: the agent plus claude model/effort flags.
public func composeAgentCommand(agent: String, model: String?, effort: String?) -> String {
    var cmd = agent
    if let model { cmd += " --model \(model)" }
    if let effort { cmd += " --effort \(effort)" }
    return cmd
}

/// argv form of composeAgentCommand: the agent (split on whitespace — the
/// custom-agent field is "binary + flags" only, never shell syntax) plus
/// claude model/effort flags, each its own element. Never joined into a
/// string that could be re-parsed by a shell.
public func composeAgentArgv(agent: String, model: String?, effort: String?) -> [String] {
    var argv = agent.split(separator: " ").map(String.init)
    if let model { argv += ["--model", model] }
    if let effort { argv += ["--effort", effort] }
    return argv
}

/// Assemble the `(command, label, resumeCmd)` a spec launches, given a
/// pre-generated `uuid` (consumed only for plain `claude`). No path
/// resolution — CreateService resolves the binary afterwards.
public func composeLaunch(spec: CreateSpec, uuid: String?)
    -> (command: String, label: String, resumeCmd: String?) {
    if spec.terminal {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
        return (shell, (shell as NSString).lastPathComponent, nil)
    }
    if let resume = spec.resume {
        // A relaunch runs the saved resume command (hardened, see below);
        // the SAVED command stays canonical so every relaunch re-wraps it.
        return (resumeLaunchCommand(resume), spec.agent, resume)
    }
    let base = composeAgentCommand(agent: spec.agent, model: spec.model, effort: spec.effort)
    if spec.agent == "claude", let uuid {
        // Inject --session-id so the conversation is resumable from cold start.
        return ("\(base) --session-id \(uuid)", spec.agent, "claude --resume \(uuid)")
    }
    return (base, spec.agent, nil)
}

/// The command a relaunch actually runs. claude writes the conversation file
/// only after the first message, so `claude --resume <uuid>` of a never-used
/// session exits with "No conversation found" — fall back to a fresh
/// `claude --session-id <uuid>`, keeping the SAME id so the next relaunch
/// resumes normally. Anything but a plain claude-resume passes through.
public func resumeLaunchCommand(_ resume: String) -> String {
    let parts = resume.split(separator: " ")
    guard parts.count == 3, parts[0] == "claude", parts[1] == "--resume" else { return resume }
    return "\(resume) || claude --session-id \(parts[2])"
}

/// Returns an error message, or nil when the create input is valid.
/// (Unlike the rust original, a nil/empty name is allowed upstream — the
/// daemon auto-names; call this only for user-typed names.)
public func validateCreate(name: String, dir: String, existing: [String]) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return "name is empty" }
    if trimmed.contains(":") || trimmed.contains(".") { return "name cannot contain ':' or '.'" }
    if existing.contains(trimmed) { return "session '\(trimmed)' already exists" }
    var isDir: ObjCBool = false
    let expanded = expandTilde(dir)
    if !FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) || !isDir.boolValue {
        return "directory not found: \(expanded)"
    }
    return nil
}

/// Returns an error message, or nil when the agent field is valid. The
/// argv-only launch path (composeAgentArgv) already removes the injection
/// risk that used to exist here — this is UX parity with
/// validateCreate/validateBranch, not a security control.
public func validateAgent(_ agent: String) -> String? {
    agent.trimmingCharacters(in: .whitespaces).isEmpty ? "agent name is empty" : nil
}

/// Validates a new worktree branch name before it becomes a filesystem path.
public func validateBranch(_ branch: String) -> String? {
    let b = branch.trimmingCharacters(in: .whitespaces)
    if b.isEmpty { return "branch name is empty" }
    if b.hasPrefix("-") { return "branch name cannot start with '-'" }
    if b.hasPrefix("/") { return "branch name cannot be an absolute path" }
    if b.split(separator: "/", omittingEmptySubsequences: false)
        .contains(where: { $0 == ".." || $0 == "." }) {
        return "branch name cannot contain '.' or '..' path segments"
    }
    return nil
}

/// Branches whose names start with `query`, case-insensitively (the branch
/// typeahead's filter — same contract as DirBrowse.list's prefix match).
public func filterBranches(_ branches: [String], query: String) -> [String] {
    let q = query.lowercased()
    guard !q.isEmpty else { return branches }
    return branches.filter { $0.lowercased().hasPrefix(q) }
}

/// Maps the form's branch field + "Create worktree" checkbox to the create
/// request. nil = stay on the current branch, session in `dir` as-is.
/// A branch that already has a worktree is always `.checkout` (the daemon
/// resolves it to that worktree's path). Empty `base` falls back to
/// `current`, then to the first branch.
public func branchPlan(input: String, current: String?, branches: [String],
                       worktrees: [String: String], createWorktree: Bool,
                       base: String) -> WorktreeSpec? {
    let branch = input.trimmingCharacters(in: .whitespaces)
    if branch.isEmpty || branch == current { return nil }
    if worktrees[branch] != nil { return .checkout(branch: branch) }
    if branches.contains(branch) {
        return createWorktree ? .existing(branch: branch) : .checkout(branch: branch)
    }
    let trimmedBase = base.trimmingCharacters(in: .whitespaces)
    let resolvedBase = trimmedBase.isEmpty ? (current ?? branches.first ?? "") : trimmedBase
    return createWorktree ? .new(branch: branch, base: resolvedBase)
                          : .checkoutNew(branch: branch, base: resolvedBase)
}

/// Expands a leading `~` to $HOME; leaves everything else untouched.
public func expandTilde(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

/// The inverse of `expandTilde`: collapses a leading $HOME back to `~` for
/// display (the form always shows home-relative paths).
public func collapseHome(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard path == home || path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
}
