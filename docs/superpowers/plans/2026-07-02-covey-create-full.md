# covey Full Session Creation (Slice 15) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Full create flow ported from amux: terminal sessions, git worktrees (new/existing branch), claude model/effort flags, `--session-id`/`--resume` wiring through Recent, agent presets from `~/.covey/config.json`, kill with worktree removal.

**Architecture:** Pure create logic (`WorktreeSpec`, compose, validate, efforts) lives in CoveyKit — shared by the daemon and the form preview. `GitOps` + `CreateService` (IO) live in CoveydCore; `IPCServer.create` prepares via CreateService when no explicit argv is given. Protocol grows optional create fields, `gitInfo`, `kill.removeWorktree`, `Session.resumeCmd`. Spec: `docs/superpowers/specs/2026-07-02-covey-create-full-design.md`.

**Tech Stack:** Swift 6.3 / SwiftPM, `swiftLanguageMode(.v5)`, macOS 26, XCTest. Tests run real `git` against temp repos (local binary, no network).

## Global Constraints

- All code, comments, and string literals in English (docs/ excepted).
- Git write operations are performed BY THE USER; each task ends with the exact command.
- Golden wire-format lines in ProtocolTests must stay valid: all new protocol fields are optionals omitted when nil.
- Effort tables verbatim from create.rs: opus `auto/low/medium/high/xhigh/max`, sonnet without `xhigh`, haiku `auto` only; `auto` emits no flag.
- Smoke REQUIRES a daemon restart first (`pkill -f coveyd; rm -f ~/.covey/coveyd.sock`).
- Test run / full suite commands as in prior plans.

---

### Task 1: CoveyKit/CreateLogic — pure port of create.rs

**Files:**
- Create: `Sources/CoveyKit/CreateLogic.swift`
- Test: `Tests/CoveyKitTests/CreateLogicTests.swift`

**Interfaces (produced):**

```swift
public enum WorktreeSpec: Codable, Equatable {
    case new(branch: String, base: String)
    case existing(branch: String)
}
public struct CreateSpec: Equatable {
    public var name: String?
    public var dir: String
    public var agent: String
    public var terminal: Bool
    public var worktree: WorktreeSpec?
    public var model: String?
    public var effort: String?
    public var resume: String?
    public init(name: String? = nil, dir: String, agent: String,
                terminal: Bool = false, worktree: WorktreeSpec? = nil,
                model: String? = nil, effort: String? = nil, resume: String? = nil)
}
public let claudeModels: [String]                      // ["opus","sonnet","haiku"]
public func effortLevels(model: String?) -> [String]
public func composeAgentCommand(agent: String, model: String?, effort: String?) -> String
public func composeLaunch(spec: CreateSpec, uuid: String?)
    -> (command: String, label: String, resumeCmd: String?)
public func validateCreate(name: String, dir: String, existing: [String]) -> String?  // error text
public func validateBranch(_ branch: String) -> String?
public func expandTilde(_ path: String) -> String
```

- [ ] **Step 1: Skeleton** — the declarations above with stub bodies
  (`[]`/`""`/`nil`/`("","",nil)`), full doc comments referencing create.rs.

- [ ] **Step 2: Failing tests** (`CreateLogicTests`, port of the rust cases):

```swift
import XCTest
@testable import CoveyKit

final class CreateLogicTests: XCTestCase {
    func testEffortLevels() {
        XCTAssertEqual(effortLevels(model: "opus"), ["auto", "low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(effortLevels(model: "sonnet"), ["auto", "low", "medium", "high", "max"])
        XCTAssertEqual(effortLevels(model: "haiku"), ["auto"])
        XCTAssertEqual(effortLevels(model: nil), ["auto"])
    }

    func testComposeAgentCommand() {
        XCTAssertEqual(composeAgentCommand(agent: "claude", model: nil, effort: nil), "claude")
        XCTAssertEqual(composeAgentCommand(agent: "claude", model: "opus", effort: nil),
                       "claude --model opus")
        XCTAssertEqual(composeAgentCommand(agent: "claude", model: "opus", effort: "max"),
                       "claude --model opus --effort max")
    }

    func testComposeLaunchTerminalUsesShell() {
        let spec = CreateSpec(dir: "/w", agent: "claude", terminal: true)
        let (cmd, label, resume) = composeLaunch(spec: spec, uuid: "u-1")
        XCTAssertEqual(cmd, ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh")
        XCTAssertEqual(label, (cmd as NSString).lastPathComponent)
        XCTAssertNil(resume)
    }

    func testComposeLaunchClaudeInjectsSessionId() {
        let spec = CreateSpec(dir: "/w", agent: "claude", model: "opus")
        let (cmd, label, resume) = composeLaunch(spec: spec, uuid: "abc")
        XCTAssertEqual(cmd, "claude --model opus --session-id abc")
        XCTAssertEqual(label, "claude")
        XCTAssertEqual(resume, "claude --resume abc")
    }

    func testComposeLaunchResumeReusesCommand() {
        let spec = CreateSpec(dir: "/w", agent: "claude", resume: "claude --resume abc")
        let (cmd, _, resume) = composeLaunch(spec: spec, uuid: nil)
        XCTAssertEqual(cmd, "claude --resume abc")
        XCTAssertEqual(resume, "claude --resume abc", "resumed session stays resumable")
    }

    func testComposeLaunchNonClaudeHasNoResume() {
        let spec = CreateSpec(dir: "/w", agent: "codex")
        let (cmd, _, resume) = composeLaunch(spec: spec, uuid: "abc")
        XCTAssertEqual(cmd, "codex")
        XCTAssertNil(resume)
    }

    func testValidateCreate() {
        XCTAssertNil(validateCreate(name: "ok", dir: "/tmp", existing: []))
        XCTAssertNotNil(validateCreate(name: "", dir: "/tmp", existing: []))
        XCTAssertNotNil(validateCreate(name: "a:b", dir: "/tmp", existing: []))
        XCTAssertNotNil(validateCreate(name: "a.b", dir: "/tmp", existing: []))
        XCTAssertNotNil(validateCreate(name: "dup", dir: "/tmp", existing: ["dup"]))
        XCTAssertNotNil(validateCreate(name: "ok", dir: "/definitely/not/here", existing: []))
    }

    func testValidateBranch() {
        XCTAssertNil(validateBranch("feature/x"))
        XCTAssertNotNil(validateBranch(""))
        XCTAssertNotNil(validateBranch("-oops"))
        XCTAssertNotNil(validateBranch("/abs"))
        XCTAssertNotNil(validateBranch("a/../b"))
        XCTAssertNotNil(validateBranch("."))
    }

    func testWorktreeSpecRoundTrip() throws {
        let enc = JSONEncoder(); let dec = JSONDecoder()
        for spec: WorktreeSpec in [.new(branch: "b", base: "main"), .existing(branch: "b")] {
            let back = try dec.decode(WorktreeSpec.self, from: enc.encode(spec))
            XCTAssertEqual(back, spec)
        }
    }
}
```

- [ ] **Step 3: red** — build + run class, expect failures.

- [ ] **Step 4: Implement** (mirror create.rs; key bodies):

```swift
public func effortLevels(model: String?) -> [String] {
    switch model {
    case "opus": return ["auto", "low", "medium", "high", "xhigh", "max"]
    case "sonnet": return ["auto", "low", "medium", "high", "max"]
    default: return ["auto"]
    }
}

public func composeAgentCommand(agent: String, model: String?, effort: String?) -> String {
    var cmd = agent
    if let model { cmd += " --model \(model)" }
    if let effort { cmd += " --effort \(effort)" }
    return cmd
}

public func composeLaunch(spec: CreateSpec, uuid: String?)
    -> (command: String, label: String, resumeCmd: String?) {
    if spec.terminal {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
        return (shell, (shell as NSString).lastPathComponent, nil)
    }
    if let resume = spec.resume {
        // A relaunch: run the saved resume command; it stays the resume command.
        return (resume, spec.agent, resume)
    }
    let base = composeAgentCommand(agent: spec.agent, model: spec.model, effort: spec.effort)
    if spec.agent == "claude", let uuid {
        return ("\(base) --session-id \(uuid)", spec.agent, "claude --resume \(uuid)")
    }
    return (base, spec.agent, nil)
}

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

public func expandTilde(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}
```

Note the deliberate difference from the rust `validate_create`: covey allows
`name == nil` (auto `s-N`) — the form calls `validateCreate` only when the
user typed a name.

- [ ] **Step 5: green.** **Step 6: commit**

```bash
git add Sources/CoveyKit/CreateLogic.swift Tests/CoveyKitTests/CreateLogicTests.swift
git commit -m "feat(covey): CreateLogic — pure create.rs port in CoveyKit"
```

---

### Task 2: CoveydCore/GitOps + tests vs a real temp repo

**Files:**
- Create: `Sources/CoveydCore/GitOps.swift`
- Test: `Tests/CoveydCoreTests/GitOpsTests.swift`

**Interfaces (produced):** enum `GitOps` with static funcs per spec §1
(`repoRoot`, `currentBranch`, `localBranches`, `branchExists`,
`worktreeForBranch`, `ensureGitignore`, `prepareWorktree`,
`prepareWorktreeExisting`, `removeWorktree`, `resolveAgentPath`).

- [ ] **Step 1: Skeleton** — all signatures, bodies `nil`/`[]`/`throws`-stub:

```swift
import Foundation

/// Blocking git plumbing for session creation (port of the needed slice of
/// amux-core git.rs). Every call shells out to `git -C`; callers keep these
/// off hot paths and outside registry locks.
public enum GitOps {
    public struct GitError: Error, CustomStringConvertible {
        public let description: String
        init(_ d: String) { description = d }
    }

    @discardableResult
    static func run(_ dir: String, _ args: [String]) throws -> String { "" }

    public static func repoRoot(_ dir: String) -> String? { nil }
    public static func currentBranch(_ repo: String) -> String? { nil }
    public static func localBranches(_ repo: String) -> [String] { [] }
    public static func branchExists(_ repo: String, _ branch: String) -> Bool { false }
    public static func worktreeForBranch(_ repo: String, _ branch: String) -> String? { nil }
    public static func ensureGitignore(_ repo: String, entry: String) throws {}
    public static func prepareWorktree(repo: String, wtPath: String,
                                       newBranch: String, base: String) throws {}
    public static func prepareWorktreeExisting(repo: String, wtPath: String,
                                               branch: String) throws {}
    public static func removeWorktree(repo: String, wtPath: String) throws {}
    public static func resolveAgentPath(_ cmd: String) -> String? { nil }
}
```

- [ ] **Step 2: Failing tests** — fixture makes a real repo:

```swift
import XCTest
@testable import CoveydCore

final class GitOpsTests: XCTestCase {
    private var repo = ""

    override func setUpWithError() throws {
        repo = "\(NSTemporaryDirectory())covey-git-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try sh("git -C '\(repo)' init -q -b main")
        try sh("git -C '\(repo)' -c user.email=t@t -c user.name=t commit --allow-empty -q -m init")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: repo)
    }

    private func sh(_ cmd: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw GitOps.GitError("sh failed: \(cmd)") }
    }

    func testRepoRootAndBranches() throws {
        let root = GitOps.repoRoot(repo)
        XCTAssertEqual(root.map { URL(fileURLWithPath: $0).lastPathComponent },
                       URL(fileURLWithPath: repo).lastPathComponent.map { String($0) } == nil
                       ? nil : URL(fileURLWithPath: repo).lastPathComponent)
        XCTAssertNil(GitOps.repoRoot("/tmp"))
        XCTAssertEqual(GitOps.currentBranch(repo), "main")
        XCTAssertEqual(GitOps.localBranches(repo), ["main"])
        XCTAssertTrue(GitOps.branchExists(repo, "main"))
        XCTAssertFalse(GitOps.branchExists(repo, "nope"))
    }

    func testPrepareWorktreeNewBranch() throws {
        let wt = "\(repo)/.worktrees/feat"
        try GitOps.ensureGitignore(repo, entry: ".worktrees/")
        try GitOps.prepareWorktree(repo: repo, wtPath: wt, newBranch: "feat", base: "main")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt))
        XCTAssertTrue(GitOps.branchExists(repo, "feat"))
        let ignore = try String(contentsOfFile: "\(repo)/.gitignore", encoding: .utf8)
        XCTAssertTrue(ignore.contains(".worktrees/"))
        // idempotent gitignore
        try GitOps.ensureGitignore(repo, entry: ".worktrees/")
        let again = try String(contentsOfFile: "\(repo)/.gitignore", encoding: .utf8)
        XCTAssertEqual(ignore, again)
        // duplicate branch → error
        XCTAssertThrowsError(try GitOps.prepareWorktree(
            repo: repo, wtPath: "\(repo)/.worktrees/feat2", newBranch: "feat", base: "main"))
        XCTAssertEqual(GitOps.worktreeForBranch(repo, "feat").map {
            URL(fileURLWithPath: $0).lastPathComponent
        }, "feat")
    }

    func testPrepareWorktreeExistingAndRemove() throws {
        try sh("git -C '\(repo)' branch other")
        let wt = "\(repo)/.worktrees/other"
        try GitOps.prepareWorktreeExisting(repo: repo, wtPath: wt, branch: "other")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt))
        try GitOps.removeWorktree(repo: repo, wtPath: wt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt))
        XCTAssertThrowsError(try GitOps.prepareWorktreeExisting(
            repo: repo, wtPath: "\(repo)/.worktrees/ghost", branch: "ghost"))
    }

    func testStaleWorktreePathIsCleared() throws {
        let wt = "\(repo)/.worktrees/feat"
        // an orphan non-empty dir at the target path, unknown to git
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        try "junk".write(toFile: "\(wt)/junk.txt", atomically: true, encoding: .utf8)
        try GitOps.prepareWorktree(repo: repo, wtPath: wt, newBranch: "feat", base: "main")
        XCTAssertTrue(GitOps.branchExists(repo, "feat"), "orphan dir must not block the add")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(wt)/junk.txt"))
    }

    func testResolveAgentPath() {
        XCTAssertEqual(GitOps.resolveAgentPath("sh"), "/bin/sh")
        XCTAssertNil(GitOps.resolveAgentPath("definitely-not-a-binary-xyz"))
        XCTAssertNil(GitOps.resolveAgentPath(""))
    }
}
```

NB: `testRepoRootAndBranches` — simplify the awkward first assert to
`XCTAssertNotNil(root)` + suffix check `root!.hasSuffix(URL(fileURLWithPath: repo).lastPathComponent)`
(temp paths go through /private symlinks; compare canonical suffixes).

- [ ] **Step 3: red.** **Step 4: Implement** — `run` via Process
  (`/usr/bin/git`? use `/usr/bin/env git`), capture stdout+stderr, non-zero →
  `GitError(stderr)`. Port each function per spec §1; `worktreeForBranch`
  parses `worktree list --porcelain` blocks (`worktree <path>` + `branch
  refs/heads/<name>`); `resolveAgentPath` via
  `Process("/bin/sh", ["-c", "command -v -- \"$0\"", bin])`.

- [ ] **Step 5: green.** **Step 6: commit**

```bash
git add Sources/CoveydCore/GitOps.swift Tests/CoveydCoreTests/GitOpsTests.swift
git commit -m "feat(coveyd): GitOps — worktree plumbing (git.rs port)"
```

---

### Task 3: CoveydCore/CreateService (IO orchestration)

**Files:**
- Create: `Sources/CoveydCore/CreateService.swift`
- Test: `Tests/CoveydCoreTests/CreateServiceTests.swift`

**Interfaces (produced):**

```swift
public enum CreateService {
    public struct Prepared: Equatable {
        public var finalDir: String
        public var argv: [String]
        public var label: String
        public var worktreeRepo: String?
        public var resumeCmd: String?
    }
    public static func prepare(_ spec: CreateSpec) throws -> Prepared
}
```

- [ ] **Step 1: Skeleton + failing tests**

Tests (same temp-repo fixture as GitOpsTests — copy the small `sh` helper):

```swift
    func testPlainAgentPrepared() throws {
        let p = try CreateService.prepare(CreateSpec(dir: "/tmp", agent: "sh"))
        XCTAssertEqual(p.finalDir, "/tmp")
        XCTAssertEqual(p.argv.prefix(2), ["/bin/sh", "-c"])
        XCTAssertEqual(p.argv.last, "/bin/sh")   // "sh" resolved to an absolute path
        XCTAssertNil(p.worktreeRepo)
        XCTAssertNil(p.resumeCmd)
    }

    func testTerminalPrepared() throws {
        let p = try CreateService.prepare(CreateSpec(dir: "/tmp", agent: "sh", terminal: true))
        XCTAssertEqual(p.argv, [ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"])
        XCTAssertNil(p.resumeCmd)
    }

    func testClaudeGetsSessionIdAndResume() throws {
        let p = try CreateService.prepare(CreateSpec(dir: "/tmp", agent: "claude", model: "opus"))
        let cmd = p.argv.last ?? ""
        XCTAssertTrue(cmd.contains("--session-id "), cmd)
        XCTAssertTrue(p.resumeCmd?.hasPrefix("claude --resume ") == true)
    }

    func testWorktreeNewBranch() throws {
        let p = try CreateService.prepare(CreateSpec(
            dir: repo, agent: "sh",
            worktree: .new(branch: "feat", base: "main")))
        XCTAssertTrue(p.finalDir.hasSuffix(".worktrees/feat"))
        XCTAssertEqual(p.worktreeRepo.map { URL(fileURLWithPath: $0).lastPathComponent },
                       URL(fileURLWithPath: repo).lastPathComponent)
        XCTAssertTrue(GitOps.branchExists(repo, "feat"))
    }

    func testWorktreeExistingCheckedOutInRoot() throws {
        // current branch (main) is checked out in the root → plain session there
        let p = try CreateService.prepare(CreateSpec(
            dir: repo, agent: "sh", worktree: .existing(branch: "main")))
        XCTAssertNil(p.worktreeRepo, "root checkout is not a removable worktree")
        XCTAssertEqual(URL(fileURLWithPath: p.finalDir).lastPathComponent,
                       URL(fileURLWithPath: repo).lastPathComponent)
    }

    func testWorktreeNotARepoThrows() {
        XCTAssertThrowsError(try CreateService.prepare(CreateSpec(
            dir: "/tmp", agent: "sh", worktree: .existing(branch: "main"))))
    }
```

- [ ] **Step 2: red.** **Step 3: Implement** — direct port of
  `create_session` + `create_worktree_session` using CreateLogic + GitOps:
  uuid only for plain non-terminal `claude` without resume; command
  resolution: first word without `/` → `GitOps.resolveAgentPath`, rebuild;
  terminal argv `[shell]`, agent argv `["/bin/sh", "-c", command]`;
  worktree branch: `.new` → ensureGitignore + prepareWorktree, dir = wt,
  worktreeRepo = repo; `.existing` → worktreeForBranch: root-same-dir →
  (repo, nil), linked → (path, repo), none → prepare + (wt, repo). Root
  same-dir check via canonical paths (`URL.standardizedFileURL.resolvingSymlinksInPath`).

- [ ] **Step 4: green + full suite.** **Step 5: commit**

```bash
git add Sources/CoveydCore/CreateService.swift Tests/CoveydCoreTests/CreateServiceTests.swift
git commit -m "feat(coveyd): CreateService — worktree/terminal/resume orchestration"
```

---

### Task 4: Protocol + daemon wiring + registry fields

**Files:**
- Modify: `Sources/CoveyKit/Protocol.swift`, `Sources/CoveyKit/Models.swift`,
  `Sources/CoveyKit/IPCClient.swift`
- Modify: `Sources/CoveydCore/IPCServer.swift`,
  `Sources/CoveydCore/SessionRegistry.swift`,
  `Sources/CoveydCore/RegistryStore.swift`
- Test: `Tests/CoveyKitTests/ProtocolTests.swift`,
  `Tests/CoveydCoreTests/IPCServerTests.swift`,
  `Tests/CoveydCoreTests/SessionRegistryTests.swift` (append)

- [ ] **Step 1: Protocol/model changes**

1. `Session` + `public var resumeCmd: String?` (init default nil, placed last).
2. `SessionMeta` + `resumeCmd: String?`, `worktreeRepo: String?` (init defaults).
3. `Op`:

```swift
        case create(dir: String, agent: String, argv: [String]?, name: String?,
                    terminal: Bool?, worktree: WorktreeSpec?, model: String?,
                    effort: String?, resume: String?)
        case kill(name: String, removeWorktree: Bool?)
        case gitInfo(dir: String)
```

4. `Result` + `case gitInfo(repoRoot: String?, currentBranch: String?, branches: [String])`.

Fix ALL construction/match sites the compiler flags (IPCClient create/kill,
IPCServer dispatch, tests — add `, terminal: nil, worktree: nil, model: nil,
effort: nil, resume: nil` / `removeWorktree: nil` or use new client defaults).
Golden lines in ProtocolTests stay unchanged (optionals omitted); ADD golden
asserts for the extended create and kill with the new fields nil to prove it.

5. `IPCClient`:

```swift
    public func create(dir: String, agent: String, argv: [String]? = nil,
                       name: String? = nil, terminal: Bool? = nil,
                       worktree: WorktreeSpec? = nil, model: String? = nil,
                       effort: String? = nil, resume: String? = nil) async throws -> Session
    public func kill(name: String, removeWorktree: Bool? = nil) async throws
    public func gitInfo(dir: String) async throws
        -> (repoRoot: String?, currentBranch: String?, branches: [String])
```

- [ ] **Step 2: Registry + dispatch**

1. `SessionRegistry.create` gains `worktreeRepo: String? = nil`,
   `resumeCmd: String? = nil` → into `Session(...)` and `SessionMeta`;
   `persistNow` copies both. Add
   `private var pendingWorktreeRemoval: [String: (repo: String, path: String)] = [:]`
   + `public func markWorktreeRemoval(name: String)` (looks up the entry's
   `worktreeRepo`/dir under the lock); in `handleExit`, after the entry is
   removed and persisted:

```swift
        if let pending = removal {   // captured under the lock
            try? GitOps.removeWorktree(repo: pending.repo, wtPath: pending.path)
        }
```

2. `IPCServer.dispatch`:

```swift
        case let .create(dir, agent, argv, name, terminal, worktree, model, effort, resume):
            do {
                if let argv {   // explicit argv: the raw path (tests, compatibility)
                    let s = try registry.create(dir: dir, agent: agent, argv: argv, name: name)
                    attachOutputFanout(for: s.name)
                    reply(.session(s))
                } else {
                    let spec = CreateSpec(name: name, dir: expandTilde(dir), agent: agent,
                                          terminal: terminal ?? false, worktree: worktree,
                                          model: model, effort: effort, resume: resume)
                    let prepared = try CreateService.prepare(spec)   // git IO, no registry lock
                    let s = try registry.create(dir: prepared.finalDir, agent: prepared.label,
                                                argv: prepared.argv, name: name,
                                                worktreeRepo: prepared.worktreeRepo,
                                                resumeCmd: prepared.resumeCmd)
                    attachOutputFanout(for: s.name)
                    reply(.session(s))
                }
            } catch let e as RegistryError { reply(errorResult(e)) }
            catch { reply(.error(code: "createFailed", message: "\(error)")) }

        case let .kill(name, removeWorktree):
            guard registry.get(name: name) != nil else { return notFound(name) }
            if removeWorktree == true { registry.markWorktreeRemoval(name: name) }
            registry.kill(name: name); reply(.ok)

        case let .gitInfo(dir):
            let root = GitOps.repoRoot(expandTilde(dir))
            reply(.gitInfo(repoRoot: root,
                           currentBranch: root.flatMap { GitOps.currentBranch($0) },
                           branches: root.map { GitOps.localBranches($0) } ?? []))
```

- [ ] **Step 3: Tests** (append):

```swift
    // IPCServerTests
    func testCreateWithWorktreeAndKillRemoveWorktree() throws { /* temp repo fixture;
        create via server with worktree .new; assert session dir ends .worktrees/wt-branch,
        worktreeRepo set; kill(removeWorktree: true); waitUntil dir gone */ }

    func testGitInfoRepoAndNonRepo() { /* .gitInfo on temp repo → root/main/["main"];
        on NSTemporaryDirectory() → nils/[] */ }

    // SessionRegistryTests
    func testResumeAndWorktreeRepoPersistIntoMeta() throws { /* create with
        worktreeRepo/resumeCmd → spy.last carries both */ }
```

Write these fully in the file (fixtures as in Tasks 2–3); plus ProtocolTests
round-trips: extended create op, `kill(name:removeWorktree:)`, `.gitInfo`
result, Session with resumeCmd.

- [ ] **Step 4: build (compiler drives remaining match-site fixes) + affected
  classes + full suite.** **Step 5: commit**

```bash
git add Sources/CoveyKit/Protocol.swift Sources/CoveyKit/Models.swift Sources/CoveyKit/IPCClient.swift Sources/CoveydCore/IPCServer.swift Sources/CoveydCore/SessionRegistry.swift Sources/CoveydCore/RegistryStore.swift Tests/CoveyKitTests/ProtocolTests.swift Tests/CoveydCoreTests/IPCServerTests.swift Tests/CoveydCoreTests/SessionRegistryTests.swift
git commit -m "feat(covey): create/kill/gitInfo protocol + daemon create pipeline"
```

---

### Task 5: GUI — config, full form, kill toggle, resume plumbing

**Files:**
- Create: `Sources/CoveyKit/CoveyConfig.swift`
- Modify: `Sources/covey/Views/Sheets.swift` (NewSessionSheet rewrite, KillSheet toggle)
- Modify: `Sources/covey/AppModel.swift` (relaunch resume, pushRecent resumeCmd)
- Test: `Tests/CoveyAppTests/AppModelChromeTests.swift` (append), `Tests/CoveyAppTests/StateStoreTests.swift` (none) — plus `CoveyConfigTests` in CoveyAppTests

- [ ] **Step 1: CoveyConfig**

```swift
import Foundation

/// User-editable app config (`~/.covey/config.json`), read-only at runtime.
public struct CoveyConfig: Codable, Equatable {
    public var defaultAgent: String?
    public var agentPresets: [String]?

    public static func load(path: String = defaultPath) -> CoveyConfig {
        guard let data = FileManager.default.contents(atPath: path),
              let cfg = try? JSONDecoder().decode(CoveyConfig.self, from: data)
        else { return CoveyConfig() }
        return cfg
    }

    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".covey/config.json").path
    }

    /// Presets for the agent picker: config or the built-in default.
    public var presets: [String] {
        let list = agentPresets ?? ["claude", "codex"]
        if let defaultAgent, !list.contains(defaultAgent) { return [defaultAgent] + list }
        if let defaultAgent, let idx = list.firstIndex(of: defaultAgent), idx != 0 {
            var l = list; l.remove(at: idx); return [defaultAgent] + l
        }
        return list
    }
}
```

Test (`CoveyConfigTests`): missing file → defaults; round-trip file; default
agent reordered first.

- [ ] **Step 2: AppModel resume plumbing**

- `pushRecent` sites (exited event + lost merge): pass
  `resumeCmd: s.resumeCmd`.
- `relaunchRecent`:

```swift
    public func relaunchRecent(_ r: RecentSession) async {
        do { _ = try await client.create(dir: r.dir, agent: r.agent, name: r.name,
                                         resume: r.resumeCmd) }
        catch { toast = errorText(error) }
    }
```

- `kill(_ name: String, removeWorktree: Bool = false)` — pass through to the
  client.
- Tests: exited claude-ish session carries resumeCmd into recents (daemon-side
  create with resume via registry.create(resumeCmd:) fixture); relaunch sends
  resume (assert via daemon backfill…, or simpler: registry-level create
  called with resume → session argv contains "--resume"; use the IPC path).

- [ ] **Step 3: NewSessionSheet rewrite** — full form per spec §5:

```swift
struct NewSessionSheet: View {
    let model: AppModel
    @State private var name = ""
    @State private var dir = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var terminal = false
    @State private var useWorktree = false
    @State private var branch = ""
    @State private var base = ""
    @State private var agent = ""
    @State private var customAgent = ""
    @State private var model_ = ""          // claude model ("" = default)
    @State private var effort = "auto"
    @State private var repoRoot: String?
    @State private var currentBranch: String?
    @State private var branches: [String] = []
    @State private var error: String?
    private let config = CoveyConfig.load()

    // …form body: Name, Directory+Browse, Terminal toggle,
    // git block (worktree toggle + branch/base pickers) when repoRoot != nil,
    // agent block (preset Picker + custom field + claude model/effort) when !terminal,
    // command preview, inline error, Cancel/Create.
}
```

Key behaviors (write in full during implementation):
- `.task(id: dir)` → `try? await model.gitInfo(dir)` (add thin
  `AppModel.gitInfo(_:)` passthrough to the client) → fills
  repoRoot/currentBranch/branches; base defaults to currentBranch.
- Branch row: `Picker` over `branches` + a "new branch…" toggle exposing a
  TextField (native reinterpretation of the typeahead); `validateBranch`
  inline.
- Preview: `Text(composeAgentCommand(agent: effectiveAgent, model: model_.isEmpty ? nil : model_, effort: effort == "auto" ? nil : effort))`.
- Create button: local `validateCreate` when name non-empty; assemble
  `worktree: useWorktree ? (creatingNew ? .new(branch:base:) : .existing(branch:)) : nil`;
  `await model.createFull(...)` — a new AppModel passthrough calling
  `client.create` with every field, toasting errors.
- Effort segmented picker options = `effortLevels(model:)`; reset effort to
  "auto" when the model changes and the current effort vanishes.

- [ ] **Step 4: KillSheet toggle**

```swift
struct KillSheet: View {
    let model: AppModel
    let name: String
    @State private var removeWorktree = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kill session \"\(name)\"?").font(.headline)
            if model.sessions.first(where: { $0.name == name })?.worktreeRepo != nil {
                Toggle("Also remove the git worktree", isOn: $removeWorktree)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Kill", role: .destructive) {
                    let rm = removeWorktree
                    Task {
                        await model.kill(name, removeWorktree: rm)
                        model.modal = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
```

- [ ] **Step 5: build + full suite.** **Step 6: commit**

```bash
git add Sources/CoveyKit/CoveyConfig.swift Sources/covey/Views/Sheets.swift Sources/covey/AppModel.swift Tests/CoveyAppTests/AppModelChromeTests.swift Tests/CoveyAppTests/CoveyConfigTests.swift
git commit -m "feat(covey): full new-session form, kill worktree toggle, resume relaunch"
```

---

### Task 6: Smoke (user; daemon restart REQUIRED) + docs commit

Per spec §8. Then:

```bash
git add docs/superpowers/plans/2026-07-02-covey-create-full.md
git commit -m "docs: slice 15 implementation plan — full session creation"
```

## Definition of Done (spec §8)

1. Build + full suite green (real-git tests included).
2. Smoke: terminal session; claude with model/effort flags visible; worktree
   new/existing flows; kill removes the worktree; claude resume via Recent
   relaunch AND via lost-after-daemon-restart; config presets picked up.
3. Vim off: the form is fully mouse-operable.
