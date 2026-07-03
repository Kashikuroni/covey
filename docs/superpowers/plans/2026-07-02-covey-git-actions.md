# covey Git Actions (Slice 16) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Live `⎇/⧉ branch +N −M` on session cards and three keyboard git actions: promote worktree (`space g p`), delete session branch (`space g b`), cleanup merged branches (`space g c`).

**Architecture:** GitOps grows the git.rs mutation/read set; a `GitMonitor` poller fills `Session.git` and emits `gitChanged`; four new protocol ops route through the daemon (git stays daemon-owned). Three keyboard sheets port `modal_git`. Spec: `docs/superpowers/specs/2026-07-02-covey-git-actions-design.md`.

**Tech Stack:** Swift 6.3 / SwiftPM, `swiftLanguageMode(.v5)`, macOS 26, XCTest (real git in temp repos).

## Global Constraints

- All code, comments, and string literals in English (docs/ excepted).
- Git write operations are performed BY THE USER; commits batched per task.
- Git READS use `LC_ALL=C` + `GIT_OPTIONAL_LOCKS=0`; mutations only `LC_ALL=C`.
- `protectedBranches = ["main", "master", "develop", "dev"]` lives in CoveyKit (Models.swift).
- Smoke REQUIRES a daemon restart.
- Test run / full suite commands as in prior plans.

---

### Task 1: GitOps extensions + protectedBranches

**Files:**
- Modify: `Sources/CoveyKit/Models.swift` (protectedBranches constant)
- Modify: `Sources/CoveydCore/GitOps.swift`
- Test: `Tests/CoveydCoreTests/GitOpsTests.swift` (append)

**Interfaces (produced):**

```swift
// CoveyKit/Models.swift
public let protectedBranches = ["main", "master", "develop", "dev"]

// GitOps additions
static func isDirty(_ dir: String) -> Bool
static func stashPush(_ dir: String) throws
static func stashPop(_ dir: String) throws
static func checkout(repo: String, branch: String) throws
static func promoteWorktree(repo: String, wtDir: String, branch: String) throws
static func deleteBranch(repo: String, branch: String) throws
static func listMergedBranches(_ repo: String) -> [String]
static func readGitInfo(_ dir: String) -> GitInfo?
static func parseShortstat(_ s: String) -> (added: Int, removed: Int)
```

- [ ] **Step 1: Failing tests (append to GitOpsTests)**

```swift
    func testParseShortstat() {
        XCTAssertEqual(GitOps.parseShortstat(" 2 files changed, 10 insertions(+), 3 deletions(-)").added, 10)
        XCTAssertEqual(GitOps.parseShortstat(" 2 files changed, 10 insertions(+), 3 deletions(-)").removed, 3)
        XCTAssertEqual(GitOps.parseShortstat(" 1 file changed, 1 insertion(+)").added, 1)
        XCTAssertEqual(GitOps.parseShortstat(" 1 file changed, 1 insertion(+)").removed, 0)
        XCTAssertEqual(GitOps.parseShortstat("").added, 0)
    }

    func testReadGitInfo() throws {
        try "line\n".write(toFile: "\(repo)/f.txt", atomically: true, encoding: .utf8)
        try sh("git -C '\(repo)' add f.txt && git -C '\(repo)' -c user.email=t@t -c user.name=t commit -q -m f")
        var info = GitOps.readGitInfo(repo)
        XCTAssertEqual(info?.branch, "main")
        XCTAssertEqual(info?.added, 0)
        try "line\nmore\n".write(toFile: "\(repo)/f.txt", atomically: true, encoding: .utf8)
        info = GitOps.readGitInfo(repo)
        XCTAssertEqual(info?.added, 1)
        XCTAssertNil(GitOps.readGitInfo(NSTemporaryDirectory()))
    }

    func testPromoteWorktreeMovesDirtyChanges() throws {
        let wt = "\(repo)/.worktrees/feat"
        try GitOps.prepareWorktree(repo: repo, wtPath: wt, newBranch: "feat", base: "main")
        try "wip".write(toFile: "\(wt)/wip.txt", atomically: true, encoding: .utf8)
        try GitOps.promoteWorktree(repo: repo, wtDir: wt, branch: "feat")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt), "worktree removed")
        XCTAssertEqual(GitOps.currentBranch(repo), "feat", "branch checked out in root")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(repo)/wip.txt"),
                      "uncommitted file travelled via the stash")
    }

    func testDeleteBranchMergedOnly() throws {
        try sh("git -C '\(repo)' branch merged-b")
        try GitOps.deleteBranch(repo: repo, branch: "merged-b")
        XCTAssertFalse(GitOps.branchExists(repo, "merged-b"))
        // an unmerged branch refuses -d
        try sh("git -C '\(repo)' checkout -q -b unmerged && touch '\(repo)/u.txt' && git -C '\(repo)' add u.txt && git -C '\(repo)' -c user.email=t@t -c user.name=t commit -q -m u && git -C '\(repo)' checkout -q main")
        XCTAssertThrowsError(try GitOps.deleteBranch(repo: repo, branch: "unmerged"))
    }

    func testListMergedBranches() throws {
        try sh("git -C '\(repo)' branch merged-b")
        let merged = GitOps.listMergedBranches(repo)
        XCTAssertTrue(merged.contains("merged-b"))
        XCTAssertFalse(merged.contains("main"), "current branch excluded")
    }
```

- [ ] **Step 2: red.** **Step 3: Implement** — additions to GitOps
  (mirror git.rs; `run` gains env: refactor `run` to accept
  `readOnly: Bool = false`, setting `LC_ALL=C` always and
  `GIT_OPTIONAL_LOCKS=0` when readOnly; existing read helpers switch to
  readOnly):

```swift
    public static func isDirty(_ dir: String) -> Bool {
        !((try? run(dir, ["status", "--porcelain"], readOnly: true)) ?? "").isEmpty
    }

    public static func stashPush(_ dir: String) throws {
        try run(dir, ["stash", "push", "--include-untracked", "-m", "covey-promote"])
    }

    public static func stashPop(_ dir: String) throws {
        try run(dir, ["stash", "pop"])
    }

    public static func checkout(repo: String, branch: String) throws {
        try run(repo, ["checkout", branch])
    }

    /// Port of git.rs promote_worktree: stash dirty changes in the worktree,
    /// remove it, check the branch out in the repo root, pop the stash there
    /// (the stash lives in the shared .git). Errors short-circuit.
    public static func promoteWorktree(repo: String, wtDir: String, branch: String) throws {
        let dirty = isDirty(wtDir)
        if dirty { try stashPush(wtDir) }
        try run(repo, ["worktree", "remove", wtDir])
        try checkout(repo: repo, branch: branch)
        if dirty { try stashPop(repo) }
    }

    public static func deleteBranch(repo: String, branch: String) throws {
        try run(repo, ["branch", "-d", branch])
    }

    /// Local branches fully merged into HEAD, excluding the current one.
    /// Protected branches are INCLUDED so callers can lock them in the UI.
    public static func listMergedBranches(_ repo: String) -> [String] {
        guard let out = try? run(repo, ["branch", "--merged", "HEAD",
                                        "--format=%(refname:short)"], readOnly: true)
        else { return [] }
        let current = currentBranch(repo) ?? ""
        return out.split(separator: "\n").map(String.init)
            .filter { !$0.isEmpty && $0 != current }
    }

    /// Branch + working-tree shortstat, or nil outside a repo (git.rs read()).
    public static func readGitInfo(_ dir: String) -> GitInfo? {
        guard repoRoot(dir) != nil else { return nil }
        guard let branch = currentBranch(dir)
            ?? (try? run(dir, ["rev-parse", "--short", "HEAD"], readOnly: true))
        else { return nil }
        let stat = (try? run(dir, ["diff", "--shortstat"], readOnly: true)) ?? ""
        let (added, removed) = parseShortstat(stat)
        return GitInfo(branch: branch, added: UInt32(added), removed: UInt32(removed))
    }

    public static func parseShortstat(_ s: String) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for part in s.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            guard let n = p.split(separator: " ").first.flatMap({ Int($0) }) else { continue }
            if p.contains("insertion") { added = n }
            else if p.contains("deletion") { removed = n }
        }
        return (added, removed)
    }
```

`run` signature change:

```swift
    @discardableResult
    static func run(_ dir: String, _ args: [String], readOnly: Bool = false) throws -> String {
        // …existing body, plus:
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        if readOnly { env["GIT_OPTIONAL_LOCKS"] = "0" }
        p.environment = env
```

and flip the existing pure-read helpers (`repoRoot`, `currentBranch`,
`localBranches`, `branchExists`, `worktreeForBranch`,
`isRegisteredWorktree`) to `readOnly: true`.

- [ ] **Step 4: green + full suite.** **Step 5: commit**

```bash
git add Sources/CoveyKit/Models.swift Sources/CoveydCore/GitOps.swift Tests/CoveydCoreTests/GitOpsTests.swift
git commit -m "feat(coveyd): GitOps promote/delete/merged/read (git.rs port)"
```

---

### Task 2: GitMonitor + registry.updateGit + event

**Files:**
- Create: `Sources/CoveydCore/GitMonitor.swift`
- Modify: `Sources/CoveydCore/SessionRegistry.swift` (updateGit)
- Modify: `Sources/CoveyKit/Protocol.swift` (gitChanged event)
- Modify: `Sources/CoveydCore/IPCServer.swift` (optional gitMonitor wiring)
- Modify: `Sources/coveyd/main.swift`, `Tests/CoveyAppTests/AppTestSupport.swift` (wire + expose)
- Test: `Tests/CoveydCoreTests/GitMonitorTests.swift`, ProtocolTests (append)

**Interfaces (produced):**

```swift
public final class GitMonitor {
    public var onGitChanged: ((String, GitInfo?) -> Void)?
    public init(interval: TimeInterval = 5, snapshot: @escaping () -> [(name: String, dir: String)])
    public func start(); public func stop(); public func tick()
}
// DaemonEvent
case gitChanged(name: String, git: GitInfo?)
// SessionRegistry
public func updateGit(name: String, git: GitInfo?)
// IPCServer
public init(registry: SessionRegistry, monitor: StatusMonitor, gitMonitor: GitMonitor? = nil)
```

- [ ] **Step 1: GitMonitor (modelled on StatusMonitor)**

```swift
import Foundation
import CoveyKit

/// Polls each live session's git info (branch + shortstat) and reports
/// changes. Slower cadence than the status poller — git shells out per dir.
public final class GitMonitor {
    public var onGitChanged: ((String, GitInfo?) -> Void)?

    private let snapshot: () -> [(name: String, dir: String)]
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "covey.git")
    private var timer: DispatchSourceTimer?
    private var prev: [String: GitInfo?] = [:]

    public init(interval: TimeInterval = 5,
                snapshot: @escaping () -> [(name: String, dir: String)]) {
        self.interval = interval
        self.snapshot = snapshot
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: interval)
        t.setEventHandler { [weak self] in self?.tickBody() }
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// One pass; tests call this directly.
    public func tick() {
        queue.sync { tickBody() }
    }

    private func tickBody() {
        var next: [String: GitInfo?] = [:]
        for (name, dir) in snapshot() {
            let info = GitOps.readGitInfo(dir)
            next[name] = info
            if prev[name] != info {
                onGitChanged?(name, info)
            }
        }
        prev = next   // wholesale replacement prunes removed sessions
    }
}
```

- [ ] **Step 2: registry/protocol/server/wiring**

`SessionRegistry`:

```swift
    /// Updates a live session's cached git info (transient; not persisted).
    public func updateGit(name: String, git: GitInfo?) {
        lock.lock()
        entries[name]?.session.git = git
        lock.unlock()
    }
```

`Protocol.swift`: add the `gitChanged` event case. `IPCServer.init` gains
`gitMonitor: GitMonitor? = nil` and, when present:

```swift
        gitMonitor?.onGitChanged = { [weak self, weak registry] name, git in
            registry?.updateGit(name: name, git: git)
            self?.broadcast(.event(.gitChanged(name: name, git: git)))
        }
```

`coveyd/main.swift`: create `GitMonitor(snapshot: { registry.list().map { ($0.name, $0.dir) } })`,
pass into IPCServer, `gitMonitor.start()` next to `monitor.start()`.
`AppTestSupport.TestDaemon`: same wiring + `let gitMonitor: GitMonitor` exposed.

- [ ] **Step 3: Tests**

`GitMonitorTests` (temp repo fixture as in GitOpsTests):

```swift
    func testEmitsOnChangeOnly() throws {
        var sessions = [(name: "s", dir: repo)]
        let monitor = GitMonitor(snapshot: { sessions })
        let lock = NSLock()
        var events: [(String, GitInfo?)] = []
        monitor.onGitChanged = { n, g in lock.lock(); events.append((n, g)); lock.unlock() }
        func count() -> Int { lock.lock(); defer { lock.unlock() }; return events.count }
        monitor.tick()
        XCTAssertEqual(count(), 1, "first observation emits")
        monitor.tick()
        XCTAssertEqual(count(), 1, "no change, no event")
        try "x\n".write(toFile: "\(repo)/f2.txt", atomically: true, encoding: .utf8)
        try sh("git -C '\(repo)' add f2.txt")
        monitor.tick()
        XCTAssertEqual(count(), 2, "diff change emits")
        sessions = []
        monitor.tick()
        XCTAssertEqual(count(), 2, "pruned session emits nothing")
    }
```

ProtocolTests: `.event(.gitChanged(name: "s-1", git: GitInfo(branch: "main", added: 1, removed: 2)))`
and `.event(.gitChanged(name: "s-1", git: nil))` in the round-trip list.

- [ ] **Step 4: green + full suite.** **Step 5: commit**

```bash
git add Sources/CoveydCore/GitMonitor.swift Sources/CoveydCore/SessionRegistry.swift Sources/CoveyKit/Protocol.swift Sources/CoveydCore/IPCServer.swift Sources/coveyd/main.swift Tests/CoveyAppTests/AppTestSupport.swift Tests/CoveydCoreTests/GitMonitorTests.swift Tests/CoveyKitTests/ProtocolTests.swift
git commit -m "feat(coveyd): GitMonitor poller + gitChanged event"
```

---

### Task 3: Protocol ops + dispatch + client

**Files:**
- Modify: `Sources/CoveyKit/Protocol.swift`, `Sources/CoveyKit/IPCClient.swift`
- Modify: `Sources/CoveydCore/IPCServer.swift`
- Test: ProtocolTests + IPCServerTests (append)

- [ ] **Step 1: Protocol**

`Op` additions:

```swift
        case promote(name: String)
        case deleteBranch(dir: String, branch: String)
        case mergedBranches(dir: String)
        case cleanupBranches(dir: String, branches: [String])
```

`Result` addition: `case branches([String])`.

`IPCClient`:

```swift
    public func promote(name: String) async throws {
        try await expectOK(.promote(name: name))
    }

    public func deleteBranch(dir: String, branch: String) async throws {
        try await expectOK(.deleteBranch(dir: dir, branch: branch))
    }

    public func mergedBranches(dir: String) async throws -> [String] {
        if case let .branches(list) = try await request(.mergedBranches(dir: dir)) {
            return list
        }
        throw IPCClientError.daemonError(code: "badResponse", message: "expected branches")
    }

    public func cleanupBranches(dir: String, branches: [String]) async throws {
        try await expectOK(.cleanupBranches(dir: dir, branches: branches))
    }
```

- [ ] **Step 2: dispatch**

```swift
        case let .promote(name):
            guard let session = registry.get(name: name) else { return notFound(name) }
            guard let repo = session.worktreeRepo else {
                return reply(.error(code: "promoteFailed", message: "not a worktree session"))
            }
            guard let branch = GitOps.currentBranch(session.dir) else {
                return reply(.error(code: "promoteFailed", message: "no branch checked out"))
            }
            do {
                try GitOps.promoteWorktree(repo: repo, wtDir: session.dir, branch: branch)
                reply(.ok)
            } catch { reply(.error(code: "promoteFailed", message: "\(error)")) }

        case let .deleteBranch(dir, branch):
            guard !protectedBranches.contains(branch) else {
                return reply(.error(code: "deleteBranchFailed",
                                    message: "branch '\(branch)' is protected"))
            }
            guard let repo = GitOps.repoRoot(expandTilde(dir)) else {
                return reply(.error(code: "deleteBranchFailed", message: "not a git repo"))
            }
            do { try GitOps.deleteBranch(repo: repo, branch: branch); reply(.ok) }
            catch { reply(.error(code: "deleteBranchFailed", message: "\(error)")) }

        case let .mergedBranches(dir):
            let repo = GitOps.repoRoot(expandTilde(dir))
            reply(.branches(repo.map { GitOps.listMergedBranches($0) } ?? []))

        case let .cleanupBranches(dir, branches):
            guard let repo = GitOps.repoRoot(expandTilde(dir)) else {
                return reply(.error(code: "cleanupFailed", message: "not a git repo"))
            }
            var failures: [String] = []
            for branch in branches where !protectedBranches.contains(branch) {
                do { try GitOps.deleteBranch(repo: repo, branch: branch) }
                catch { failures.append("\(branch): \(error)") }
            }
            failures.isEmpty
                ? reply(.ok)
                : reply(.error(code: "cleanupFailed",
                               message: failures.joined(separator: "; ")))
```

- [ ] **Step 3: Tests** — ProtocolTests round-trips (4 ops + `.branches`);
  IPCServerTests: promote on a non-worktree session → `promoteFailed`;
  deleteBranch protected → error; mergedBranches + cleanup against a temp
  repo (create a merged branch via `sh`, cleanup removes it; protected
  survives). Full code follows the Task-4 fixture pattern already in the file.

- [ ] **Step 4: green + full suite.** **Step 5: commit**

```bash
git add Sources/CoveyKit/Protocol.swift Sources/CoveyKit/IPCClient.swift Sources/CoveydCore/IPCServer.swift Tests/CoveyKitTests/ProtocolTests.swift Tests/CoveydCoreTests/IPCServerTests.swift
git commit -m "feat(covey): promote/deleteBranch/merged/cleanup protocol ops"
```

---

### Task 4: GUI — router, guards, sheets, card git line

**Files:**
- Modify: `Sources/covey/KeyRouter.swift` + KeyRouterTests
- Modify: `Sources/covey/AppModel.swift` + AppModelChromeTests
- Modify: `Sources/covey/Views/Sheets.swift` (3 sheets), `Sources/covey/Views/ContentView.swift` (cases), `Sources/covey/Views/SessionListView.swift` (git line), `Sources/covey/Views/WhichKeyView.swift` (un-grey g group)

- [ ] **Step 1: Router** — `KeyAction` + `promoteSelected`,
  `deleteBranchSelected`, `cleanupBranches`; `routeLeader`:
  `(.git, "p"/"b"/"c")` → those. Tests assert the three chords.

- [ ] **Step 2: AppModel** — `Modal` + `.promote(String)`,
  `.deleteBranch(String)`, `.cleanup(String)` (+ id cases in Sheets.swift);
  event apply: `case let .gitChanged(name, git): if let i = sessions.firstIndex(where: { $0.name == name }) { sessions[i].git = git }`;
  apply guards:

```swift
        case .promoteSelected:
            inputMode = .normal
            guard let s = selectedSession() else { return }
            if s.worktreeRepo == nil { toast = "not a worktree session"; return }
            modal = .promote(s.name)
        case .deleteBranchSelected:
            inputMode = .normal
            guard let s = selectedSession() else { return }
            if s.worktreeRepo != nil { toast = "cannot delete: worktree session"; return }
            guard let branch = s.git?.branch else { toast = "no git info"; return }
            if protectedBranches.contains(branch) { toast = "branch '\(branch)' is protected"; return }
            modal = .deleteBranch(s.name)
        case .cleanupBranches:
            inputMode = .normal
            guard let s = selectedSession() else { return }
            if s.git == nil { toast = "not a git repo"; return }
            modal = .cleanup(s.dir)
```

with `private func selectedSession() -> Session?` and `toast` made settable
internally (add `func showToast(_:)` or relax to `internal(set)` — pick the
first). Passthroughs: `promote(name:)`, `deleteBranch(dir:branch:)`,
`mergedBranches(dir:)`, `cleanupBranches(dir:branches:)` wrapping the client
with toast on error. Tests: guards produce toasts/modals; gitChanged updates
`sessions[i].git`.

- [ ] **Step 3: Sheets** — PromoteSheet / DeleteBranchSheet (y/Enter confirm,
  n/Esc cancel, inline error) and CleanupSheet (loads merged branches in
  `.task`, cursor list with `j/k/↑↓`, Space toggle, `a` select-all
  unprotected, `y`/Enter delete, protected rows locked with 🔒, empty state);
  keyboard via `.focusable()` content + `.onKeyPress` (slice-15 pattern).
  ContentView sheet switch gains the three cases.

- [ ] **Step 4: Card git line** (SessionListView.row, under the name row):

```swift
            if let git = session.git {
                HStack(spacing: 4) {
                    Text(session.worktreeRepo != nil ? "⧉" : "⎇")
                    Text(git.branch).lineLimit(1)
                    if git.added > 0 { Text("+\(git.added)").foregroundStyle(.green) }
                    if git.removed > 0 { Text("−\(git.removed)").foregroundStyle(.red) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
```

WhichKeyView: `g` group rows become `implemented: true` with labels sans "(later)".

- [ ] **Step 5: build + full suite.** **Step 6: commit**

```bash
git add Sources/covey/KeyRouter.swift Tests/CoveyAppTests/KeyRouterTests.swift Sources/covey/AppModel.swift Tests/CoveyAppTests/AppModelChromeTests.swift Sources/covey/Views/Sheets.swift Sources/covey/Views/ContentView.swift Sources/covey/Views/SessionListView.swift Sources/covey/Views/WhichKeyView.swift
git commit -m "feat(covey): git action sheets, guards and card git info"
```

---

### Task 5: Smoke (user; daemon restart) + docs commit

Per spec §7. Then:

```bash
git add docs/superpowers/plans/2026-07-02-covey-git-actions.md
git commit -m "docs: slice 16 implementation plan — git actions"
```

## Definition of Done (spec §7)

1. Build + full suite green.
2. Smoke: card `⎇/⧉ branch ±` live ≤5 s; promote moves dirty file to root;
   delete branch works/refuses protected; cleanup list with locks; `g` group white.
3. Vim off: sheets mouse-operable.
