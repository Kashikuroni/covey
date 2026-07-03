# covey Branch Picker Redesign (Slice 15.1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the broken horizontal branch chips in NewSessionSheet with a dir-picker-style typeahead branch field, add checkout-in-root (no worktree) create paths, and auto-open sessions in a branch's existing worktree.

**Architecture:** Pure decision logic (`filterBranches`, `branchPlan`) and two new `WorktreeSpec` cases (`.checkout`, `.checkoutNew`) live in CoveyKit. The daemon grows `GitOps.worktrees` (branch→path map, exposed through `gitInfo`) and `GitOps.createBranch`; `CreateService` handles the two new cases, reusing the existing checked-out-worktree resolution. The GUI moves NewSessionSheet into its own file and rebuilds the git block around a shared suggestion-list helper. Spec: `docs/superpowers/specs/2026-07-03-branch-picker-redesign-design.md`.

**Tech Stack:** Swift 6.3 / SwiftPM, `swiftLanguageMode(.v5)`, macOS 26, XCTest. Tests run real `git` against temp repos (local binary, no network).

## Global Constraints

- All code, comments, and string literals in English (docs/ excepted).
- Git write operations are performed BY THE USER; each task ends with the exact command to hand over.
- Golden wire-format lines in ProtocolTests must stay valid: the new `worktrees` field on `Result.gitInfo` is an optional omitted when nil; the new `WorktreeSpec` cases add no fields to existing cases.
- Exact-name matching of branches is case-sensitive; the typeahead prefix filter is case-insensitive (same contract as `DirBrowse.list`).
- Test runs: `swift test --filter <ClassName>`; full suite: `swift test`.
- Smoke REQUIRES a daemon restart first (`pkill -f coveyd; rm -f ~/.covey/coveyd.sock`).

---

### Task 1: CoveyKit — WorktreeSpec checkout cases + branchPlan/filterBranches

**Files:**
- Modify: `Sources/CoveyKit/CreateLogic.swift`
- Test: `Tests/CoveyKitTests/CreateLogicTests.swift`
- Test: `Tests/CoveyKitTests/ProtocolTests.swift`

**Interfaces:**
- Consumes: existing `WorktreeSpec`, `validateBranch`.
- Produces (used by Tasks 3 and 4):

```swift
public enum WorktreeSpec: Codable, Equatable {
    case new(branch: String, base: String)
    case existing(branch: String)
    case checkout(branch: String)                    // NEW
    case checkoutNew(branch: String, base: String)   // NEW
}
public func filterBranches(_ branches: [String], query: String) -> [String]
public func branchPlan(input: String, current: String?, branches: [String],
                       worktrees: [String: String], createWorktree: Bool,
                       base: String) -> WorktreeSpec?
```

- [ ] **Step 1: Skeleton** — in `Sources/CoveyKit/CreateLogic.swift` add the two cases to `WorktreeSpec` with doc comments, and stub the two functions:

```swift
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
```

and below `validateBranch`:

```swift
/// Branches whose names start with `query`, case-insensitively (the branch
/// typeahead's filter — same contract as DirBrowse.list's prefix match).
public func filterBranches(_ branches: [String], query: String) -> [String] {
    []
}

/// Maps the form's branch field + "Create worktree" checkbox to the create
/// request. nil = stay on the current branch, session in `dir` as-is.
/// A branch that already has a worktree is always `.checkout` (the daemon
/// resolves it to that worktree's path). Empty `base` falls back to
/// `current`, then to the first branch.
public func branchPlan(input: String, current: String?, branches: [String],
                       worktrees: [String: String], createWorktree: Bool,
                       base: String) -> WorktreeSpec? {
    nil
}
```

Run: `swift build` — compiles.

- [ ] **Step 2: Failing tests** — append to `Tests/CoveyKitTests/CreateLogicTests.swift`:

```swift
    func testFilterBranches() {
        let branches = ["main", "feat", "Fix/ui"]
        XCTAssertEqual(filterBranches(branches, query: ""), branches, "empty query keeps all")
        XCTAssertEqual(filterBranches(branches, query: "FE"), ["feat"], "case-insensitive prefix")
        XCTAssertEqual(filterBranches(branches, query: "fix"), ["Fix/ui"])
        XCTAssertEqual(filterBranches(branches, query: "zzz"), [])
    }

    func testBranchPlanStaysOnCurrent() {
        let branches = ["main", "feat"]
        XCTAssertNil(branchPlan(input: "", current: "main", branches: branches,
                                worktrees: [:], createWorktree: false, base: ""))
        XCTAssertNil(branchPlan(input: "   ", current: "main", branches: branches,
                                worktrees: [:], createWorktree: true, base: ""))
        XCTAssertNil(branchPlan(input: "main", current: "main", branches: branches,
                                worktrees: [:], createWorktree: false, base: ""))
    }

    func testBranchPlanExistingWorktreeAlwaysCheckout() {
        let wts = ["main": "/r", "wt": "/r/.worktrees/wt"]
        for create in [true, false] {
            XCTAssertEqual(branchPlan(input: "wt", current: "main",
                                      branches: ["main", "feat", "wt"], worktrees: wts,
                                      createWorktree: create, base: ""),
                           .checkout(branch: "wt"),
                           "checkbox is irrelevant when the worktree already exists")
        }
    }

    func testBranchPlanExistingBranch() {
        let branches = ["main", "feat"]
        XCTAssertEqual(branchPlan(input: "feat", current: "main", branches: branches,
                                  worktrees: [:], createWorktree: false, base: ""),
                       .checkout(branch: "feat"))
        XCTAssertEqual(branchPlan(input: " feat ", current: "main", branches: branches,
                                  worktrees: [:], createWorktree: false, base: ""),
                       .checkout(branch: "feat"), "input is trimmed")
        XCTAssertEqual(branchPlan(input: "feat", current: "main", branches: branches,
                                  worktrees: [:], createWorktree: true, base: ""),
                       .existing(branch: "feat"))
    }

    func testBranchPlanNewBranch() {
        let branches = ["main", "feat"]
        XCTAssertEqual(branchPlan(input: "new-b", current: "main", branches: branches,
                                  worktrees: [:], createWorktree: false, base: ""),
                       .checkoutNew(branch: "new-b", base: "main"),
                       "empty base defaults to the current branch")
        XCTAssertEqual(branchPlan(input: "new-b", current: "main", branches: branches,
                                  worktrees: [:], createWorktree: true, base: "feat"),
                       .new(branch: "new-b", base: "feat"))
        XCTAssertEqual(branchPlan(input: "new-b", current: nil, branches: branches,
                                  worktrees: [:], createWorktree: false, base: " "),
                       .checkoutNew(branch: "new-b", base: "main"),
                       "detached HEAD: base falls back to the first branch")
    }
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter CreateLogicTests`
Expected: FAIL — `testFilterBranches`, `testBranchPlanExistingWorktreeAlwaysCheckout`, `testBranchPlanExistingBranch`, `testBranchPlanNewBranch` (stubs return `[]`/`nil`).

- [ ] **Step 4: Implement**

```swift
public func filterBranches(_ branches: [String], query: String) -> [String] {
    let q = query.lowercased()
    guard !q.isEmpty else { return branches }
    return branches.filter { $0.lowercased().hasPrefix(q) }
}

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
```

- [ ] **Step 5: Protocol round-trip for the new cases** — in `Tests/CoveyKitTests/ProtocolTests.swift`, `testRequestOpRoundTrip`, add to the `ops` array after the second `.create(...)` entry:

```swift
            .create(dir: "/work", agent: "claude", argv: nil, name: nil,
                    terminal: nil, worktree: .checkout(branch: "feat"),
                    model: nil, effort: nil, resume: nil),
            .create(dir: "/work", agent: "claude", argv: nil, name: nil,
                    terminal: nil, worktree: .checkoutNew(branch: "feat", base: "main"),
                    model: nil, effort: nil, resume: nil),
```

- [ ] **Step 6: Green**

Run: `swift test --filter CreateLogicTests && swift test --filter ProtocolTests`
Expected: PASS.

- [ ] **Step 7: Hand the commit to the user**

```bash
git add Sources/CoveyKit/CreateLogic.swift Tests/CoveyKitTests/CreateLogicTests.swift Tests/CoveyKitTests/ProtocolTests.swift
git commit -m "feat(coveykit): checkout WorktreeSpec cases + branchPlan/filterBranches"
```

---

### Task 2: worktrees map through gitInfo (GitOps → protocol → client)

**Files:**
- Modify: `Sources/CoveydCore/GitOps.swift` (worktrees + worktreeForBranch rewrite)
- Modify: `Sources/CoveyKit/Protocol.swift:39` (`Result.gitInfo`)
- Modify: `Sources/CoveyKit/IPCClient.swift:90-96` (`gitInfo`)
- Modify: `Sources/CoveydCore/IPCServer.swift:121-125` (`.gitInfo` handler)
- Modify: `Sources/covey/AppModel.swift:196-199` (`gitInfo`)
- Test: `Tests/CoveydCoreTests/GitOpsTests.swift`
- Test: `Tests/CoveyKitTests/ProtocolTests.swift`
- Test: `Tests/CoveydCoreTests/IPCServerTests.swift`

**Interfaces:**
- Consumes: existing `GitOps.run`, `worktreeForBranch` porcelain format.
- Produces (used by Tasks 3 and 4):

```swift
// GitOps
public static func worktrees(_ repo: String) -> [String: String]   // branch -> path
// Protocol
case gitInfo(repoRoot: String?, currentBranch: String?, branches: [String],
             worktrees: [String: String]?)
// IPCClient / AppModel gitInfo now return a 4-tuple whose last member is
// worktrees: [String: String] (empty when absent / non-repo)
```

- [ ] **Step 1: Failing GitOps test** — append to `Tests/CoveydCoreTests/GitOpsTests.swift`:

```swift
    func testWorktreesMap() throws {
        var map = GitOps.worktrees(repo)
        XCTAssertEqual(Array(map.keys), ["main"], "main worktree is included")
        XCTAssertTrue(map["main"]!.hasSuffix(URL(fileURLWithPath: repo).lastPathComponent))
        try sh("git -C '\(repo)' branch other")
        try GitOps.prepareWorktreeExisting(repo: repo, wtPath: "\(repo)/.worktrees/other",
                                           branch: "other")
        try sh("git -C '\(repo)' worktree add --detach '\(repo)/.worktrees/loose'")
        map = GitOps.worktrees(repo)
        XCTAssertEqual(map.keys.sorted(), ["main", "other"], "detached worktree skipped")
        XCTAssertTrue(map["other"]!.hasSuffix(".worktrees/other"))
        XCTAssertEqual(GitOps.worktrees(NSTemporaryDirectory()), [:])
    }
```

Run: `swift test --filter GitOpsTests.testWorktreesMap`
Expected: FAIL — `worktrees` undefined (compile error is the failure here).

- [ ] **Step 2: Implement GitOps.worktrees; rewrite worktreeForBranch through it** — replace `worktreeForBranch` in `Sources/CoveydCore/GitOps.swift:62-75` with:

```swift
    /// All of the repo's worktrees as branch -> path (porcelain parse). The
    /// main worktree is included; detached worktrees carry no branch line and
    /// are skipped.
    public static func worktrees(_ repo: String) -> [String: String] {
        guard let out = try? run(repo, ["worktree", "list", "--porcelain"], readOnly: true)
        else { return [:] }
        var map: [String: String] = [:]
        var path: String?
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/"), let p = path {
                map[String(line.dropFirst("branch refs/heads/".count))] = p
                path = nil
            }
        }
        return map
    }

    /// The worktree path where `branch` is checked out, if any.
    public static func worktreeForBranch(_ repo: String, _ branch: String) -> String? {
        worktrees(repo)[branch]
    }
```

Run: `swift test --filter GitOpsTests`
Expected: PASS (including the untouched `testPrepareWorktreeNewBranch`, which exercises `worktreeForBranch`).

- [ ] **Step 3: Protocol + client + server + AppModel** — four edits:

`Sources/CoveyKit/Protocol.swift:39`:

```swift
        // `worktrees` (branch -> path) is optional so older payloads decode.
        case gitInfo(repoRoot: String?, currentBranch: String?, branches: [String],
                     worktrees: [String: String]?)
```

`Sources/CoveyKit/IPCClient.swift` `gitInfo`:

```swift
    public func gitInfo(dir: String) async throws
        -> (repoRoot: String?, currentBranch: String?, branches: [String],
            worktrees: [String: String]) {
        if case let .gitInfo(root, current, branches, worktrees)
            = try await request(.gitInfo(dir: dir)) {
            return (root, current, branches, worktrees ?? [:])
        }
        throw IPCClientError.daemonError(code: "badResponse", message: "expected gitInfo")
    }
```

`Sources/CoveydCore/IPCServer.swift` `.gitInfo` case:

```swift
        case let .gitInfo(dir):
            let root = GitOps.repoRoot(expandTilde(dir))
            reply(.gitInfo(repoRoot: root,
                           currentBranch: root.flatMap { GitOps.currentBranch($0) },
                           branches: root.map { GitOps.localBranches($0) } ?? [],
                           worktrees: root.map { GitOps.worktrees($0) } ?? [:]))
```

`Sources/covey/AppModel.swift` `gitInfo`:

```swift
    public func gitInfo(_ dir: String) async
        -> (repoRoot: String?, currentBranch: String?, branches: [String],
            worktrees: [String: String]) {
        (try? await client.gitInfo(dir: dir)) ?? (nil, nil, [], [:])
    }
```

(The sheet's `.task(id: dir)` reads tuple members by name, so it still compiles.)

- [ ] **Step 4: Update the two test call sites** —

`Tests/CoveyKitTests/ProtocolTests.swift`, `testServerMessageRoundTrip`, replace the two `.gitInfo` entries:

```swift
            .response(id: 6, result: .gitInfo(repoRoot: "/w", currentBranch: "main",
                                              branches: ["main", "dev"],
                                              worktrees: ["main": "/w"])),
            .response(id: 7, result: .gitInfo(repoRoot: nil, currentBranch: nil,
                                              branches: [], worktrees: nil)),
```

`Tests/CoveydCoreTests/IPCServerTests.swift:206-219`, update both pattern matches:

```swift
        server.handle(Request(id: 1, op: .gitInfo(dir: repo)), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(1, .gitInfo(let root, let cur, let branches, let wts)) = $0 {
                return root != nil && cur == "main" && branches == ["main"]
                    && wts?.keys.contains("main") == true
            }
            return false
        } }, "gitInfo for a repo")
        server.handle(Request(id: 2, op: .gitInfo(dir: NSTemporaryDirectory())), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(2, .gitInfo(let root, let cur, let branches, let wts)) = $0 {
                return root == nil && cur == nil && branches.isEmpty && (wts ?? [:]).isEmpty
            }
            return false
        } }, "gitInfo for a non-repo")
```

- [ ] **Step 5: Green + full suite**

Run: `swift test --filter ProtocolTests && swift test --filter IPCServerTests && swift test`
Expected: PASS everywhere (golden wire lines untouched — `worktrees` is a new optional).

- [ ] **Step 6: Hand the commit to the user**

```bash
git add Sources/CoveydCore/GitOps.swift Sources/CoveyKit/Protocol.swift Sources/CoveyKit/IPCClient.swift Sources/CoveydCore/IPCServer.swift Sources/covey/AppModel.swift Tests/CoveydCoreTests/GitOpsTests.swift Tests/CoveyKitTests/ProtocolTests.swift Tests/CoveydCoreTests/IPCServerTests.swift
git commit -m "feat(coveyd): worktrees map in gitInfo (branch -> path)"
```

---

### Task 3: daemon checkout paths — GitOps.createBranch + CreateService .checkout/.checkoutNew

**Files:**
- Modify: `Sources/CoveydCore/GitOps.swift` (createBranch)
- Modify: `Sources/CoveydCore/CreateService.swift:41-64` (switch + shared resolution)
- Test: `Tests/CoveydCoreTests/GitOpsTests.swift`
- Test: `Tests/CoveydCoreTests/CreateServiceTests.swift`

**Interfaces:**
- Consumes: `WorktreeSpec.checkout/.checkoutNew` (Task 1), `GitOps.checkout(repo:branch:)` (existing), `GitOps.worktreeForBranch`.
- Produces: `CreateService.prepare` handles all four `WorktreeSpec` cases;
  `public static func createBranch(_ repo: String, _ branch: String, base: String) throws`.

- [ ] **Step 1: Failing GitOps test** — append to `Tests/CoveydCoreTests/GitOpsTests.swift`:

```swift
    func testCreateBranch() throws {
        try GitOps.createBranch(repo, "feat", base: "main")
        XCTAssertEqual(GitOps.currentBranch(repo), "feat", "created AND checked out")
        XCTAssertThrowsError(try GitOps.createBranch(repo, "feat", base: "main"),
                             "duplicate branch")
        XCTAssertThrowsError(try GitOps.createBranch(repo, "x", base: "nope"),
                             "unknown base")
    }
```

Run: `swift test --filter GitOpsTests.testCreateBranch`
Expected: FAIL — `createBranch` undefined.

- [ ] **Step 2: Implement** — in `Sources/CoveydCore/GitOps.swift`, next to `checkout`:

```swift
    /// Creates `branch` from `base` and checks it out in the repo root.
    public static func createBranch(_ repo: String, _ branch: String, base: String) throws {
        try run(repo, ["checkout", "-b", branch, base])
    }
```

Run: `swift test --filter GitOpsTests.testCreateBranch`
Expected: PASS.

- [ ] **Step 3: Failing CreateService tests** — append to `Tests/CoveydCoreTests/CreateServiceTests.swift`:

```swift
    func testCheckoutCurrentBranchOpensRoot() throws {
        let p = try CreateService.prepare(CreateSpec(
            dir: repo, agent: "sh", worktree: .checkout(branch: "main")))
        XCTAssertNil(p.worktreeRepo)
        XCTAssertEqual(URL(fileURLWithPath: p.finalDir).lastPathComponent,
                       URL(fileURLWithPath: repo).lastPathComponent)
        XCTAssertEqual(GitOps.currentBranch(repo), "main", "no switch happened")
    }

    func testCheckoutBranchWithWorktreeOpensIt() throws {
        try sh("git -C '\(repo)' branch other")
        try sh("git -C '\(repo)' worktree add '\(repo)/.worktrees/other' other")
        let p = try CreateService.prepare(CreateSpec(
            dir: repo, agent: "sh", worktree: .checkout(branch: "other")))
        XCTAssertTrue(p.finalDir.hasSuffix(".worktrees/other"))
        XCTAssertNotNil(p.worktreeRepo, "existing worktree session is removable")
        XCTAssertEqual(GitOps.currentBranch(repo), "main", "root untouched")
    }

    func testCheckoutSwitchesRootBranch() throws {
        try sh("git -C '\(repo)' branch other")
        let p = try CreateService.prepare(CreateSpec(
            dir: repo, agent: "sh", worktree: .checkout(branch: "other")))
        XCTAssertNil(p.worktreeRepo)
        XCTAssertEqual(URL(fileURLWithPath: p.finalDir).lastPathComponent,
                       URL(fileURLWithPath: repo).lastPathComponent)
        XCTAssertEqual(GitOps.currentBranch(repo), "other", "switched in root")
    }

    func testCheckoutNewCreatesBranchInRoot() throws {
        let p = try CreateService.prepare(CreateSpec(
            dir: repo, agent: "sh", worktree: .checkoutNew(branch: "feat", base: "main")))
        XCTAssertNil(p.worktreeRepo)
        XCTAssertEqual(GitOps.currentBranch(repo), "feat")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(repo)/.worktrees/feat"),
                       "no worktree was created")
    }

    func testCheckoutNewBadNameThrows() {
        XCTAssertThrowsError(try CreateService.prepare(CreateSpec(
            dir: repo, agent: "sh", worktree: .checkoutNew(branch: "-bad", base: "main"))))
    }
```

Run: `swift test --filter CreateServiceTests`
Expected: FAIL — `switch wt` not exhaustive (compile error is the failure).

- [ ] **Step 4: Implement** — in `Sources/CoveydCore/CreateService.swift` replace the `switch wt` (lines 41-64) with:

```swift
        switch wt {
        case .new(let branch, let base):
            if let err = validateBranch(branch) { throw GitOps.GitError(err) }
            try GitOps.ensureGitignore(repo, entry: ".worktrees/")
            let path = wtFor(branch)
            try GitOps.prepareWorktree(repo: repo, wtPath: path, newBranch: branch, base: base)
            return Prepared(finalDir: path, argv: argv, label: label,
                            worktreeRepo: repo, resumeCmd: resumeCmd)
        case .existing(let branch):
            if let p = checkedOutPrepared(repo: repo, branch: branch, argv: argv,
                                          label: label, resumeCmd: resumeCmd) {
                return p
            }
            try GitOps.ensureGitignore(repo, entry: ".worktrees/")
            let path = wtFor(branch)
            try GitOps.prepareWorktreeExisting(repo: repo, wtPath: path, branch: branch)
            return Prepared(finalDir: path, argv: argv, label: label,
                            worktreeRepo: repo, resumeCmd: resumeCmd)
        case .checkout(let branch):
            if let p = checkedOutPrepared(repo: repo, branch: branch, argv: argv,
                                          label: label, resumeCmd: resumeCmd) {
                return p
            }
            try GitOps.checkout(repo: repo, branch: branch)
            return Prepared(finalDir: repo, argv: argv, label: label,
                            worktreeRepo: nil, resumeCmd: resumeCmd)
        case .checkoutNew(let branch, let base):
            if let err = validateBranch(branch) { throw GitOps.GitError(err) }
            try GitOps.createBranch(repo, branch, base: base)
            return Prepared(finalDir: repo, argv: argv, label: label,
                            worktreeRepo: nil, resumeCmd: resumeCmd)
        }
```

and add the shared resolver below `prepare` (it replaces the inline `if let checkedOut …` block the old `.existing` case carried):

```swift
    /// Where `branch` is already checked out, the session opens there: the
    /// repo's main worktree makes a plain session; a linked worktree makes a
    /// removable worktree session.
    private static func checkedOutPrepared(repo: String, branch: String, argv: [String],
                                           label: String, resumeCmd: String?) -> Prepared? {
        guard let path = GitOps.worktreeForBranch(repo, branch) else { return nil }
        if sameDir(path, repo) {
            return Prepared(finalDir: repo, argv: argv, label: label,
                            worktreeRepo: nil, resumeCmd: resumeCmd)
        }
        return Prepared(finalDir: path, argv: argv, label: label,
                        worktreeRepo: repo, resumeCmd: resumeCmd)
    }
```

- [ ] **Step 5: Green + full suite**

Run: `swift test --filter CreateServiceTests && swift test`
Expected: PASS (old `.existing` tests still green through the shared resolver).

- [ ] **Step 6: Hand the commit to the user**

```bash
git add Sources/CoveydCore/GitOps.swift Sources/CoveydCore/CreateService.swift Tests/CoveydCoreTests/GitOpsTests.swift Tests/CoveydCoreTests/CreateServiceTests.swift
git commit -m "feat(coveyd): checkout/checkoutNew create paths (branch in repo root)"
```

---

### Task 4: GUI — NewSessionSheet extraction + typeahead git block

**Files:**
- Create: `Sources/covey/Views/NewSessionSheet.swift` (moved from Sheets.swift)
- Modify: `Sources/covey/Views/Sheets.swift` (remove the moved code)
- Modify: `Sources/covey/DirBrowse.swift:43-67` (`FormField` sequence)
- Test: `Tests/CoveyAppTests/DirBrowseTests.swift:39-52`

**Interfaces:**
- Consumes: `filterBranches`, `branchPlan`, `validateBranch`, `collapseHome` (CoveyKit); `model.gitInfo` 4-tuple (Task 2).
- Produces: `formFieldSequence(terminal:isRepo:showWorktreeToggle:showBase:isClaude:customAgent:) -> [FormField]` (same `FormField` cases as today — `.worktree` is now the "Create worktree" checkbox).

- [ ] **Step 1: Mechanical move** — cut from `Sources/covey/Views/Sheets.swift` into a new `Sources/covey/Views/NewSessionSheet.swift`: the `customAgentSlot` and `newBranchSlot` constants and the whole `struct NewSessionSheet` (`Sheets.swift:19-355`). The new file starts with:

```swift
import AppKit
import SwiftUI
import CoveyKit
```

`Sheets.swift` keeps its imports, the `AppModel.Modal` extension, and every other sheet.

Run: `swift build`
Expected: compiles, no behavior change.

- [ ] **Step 2: Failing field-sequence test** — in `Tests/CoveyAppTests/DirBrowseTests.swift` replace `testFieldSequence` with:

```swift
    func testFieldSequence() {
        XCTAssertEqual(
            formFieldSequence(terminal: false, isRepo: false, showWorktreeToggle: false,
                              showBase: false, isClaude: true, customAgent: false),
            [.name, .dir, .terminal, .agent, .model, .effort])
        XCTAssertEqual(
            formFieldSequence(terminal: true, isRepo: true, showWorktreeToggle: true,
                              showBase: true, isClaude: false, customAgent: false),
            [.name, .dir, .terminal, .branch, .worktree, .base])
        XCTAssertEqual(
            formFieldSequence(terminal: false, isRepo: true, showWorktreeToggle: false,
                              showBase: false, isClaude: false, customAgent: true),
            [.name, .dir, .terminal, .branch, .agent, .customAgent])
    }
```

Run: `swift test --filter DirBrowseTests`
Expected: FAIL — old signature (compile error is the failure).

- [ ] **Step 3: New sequence** — in `Sources/covey/DirBrowse.swift` replace `formFieldSequence` (keep `FormField` as is; `.worktree` is now the checkbox row):

```swift
func formFieldSequence(terminal: Bool, isRepo: Bool, showWorktreeToggle: Bool,
                       showBase: Bool, isClaude: Bool,
                       customAgent: Bool) -> [FormField] {
    var fields: [FormField] = [.name, .dir, .terminal]
    if isRepo {
        fields.append(.branch)
        if showWorktreeToggle { fields.append(.worktree) }
        if showBase { fields.append(.base) }
    }
    if !terminal {
        fields.append(.agent)
        if customAgent { fields.append(.customAgent) }
        if isClaude {
            fields.append(.model)
            fields.append(.effort)
        }
    }
    return fields
}
```

(The sheet still calls the old signature — next step fixes it; `swift build` stays red until then.)

- [ ] **Step 4: Rework the sheet's git block** — all edits in `Sources/covey/Views/NewSessionSheet.swift`:

**4a. State.** Delete `newBranchSlot`, and the `useWorktree`, `branchChoice`, `newBranch`, `base` properties. Add:

```swift
    @State private var branchInput = ""
    @State private var branchSelected = 0
    @State private var createWorktree = false
    @State private var baseInput = ""
    @State private var baseSelected = 0
    @State private var currentBranch: String?
    @State private var worktrees: [String: String] = [:]
```

**4b. Derived.** Below `isClaude`:

```swift
    private var trimmedBranch: String { branchInput.trimmingCharacters(in: .whitespaces) }
    /// No exact match -> submitting will create this branch.
    private var branchIsNew: Bool {
        !trimmedBranch.isEmpty && !branches.contains(trimmedBranch)
    }
    /// The branch's existing worktree (the main worktree counts) — the
    /// session opens there, so the checkbox disappears.
    private var branchWorktreePath: String? {
        trimmedBranch.isEmpty ? nil : worktrees[trimmedBranch]
    }
    private var showWorktreeToggle: Bool {
        !trimmedBranch.isEmpty && trimmedBranch != currentBranch
            && branchWorktreePath == nil
    }
    private var branchEntries: [String] { filterBranches(branches, query: trimmedBranch) }
    private var baseEntries: [String] {
        filterBranches(branches, query: baseInput.trimmingCharacters(in: .whitespaces))
    }
```

and `fieldSequence` becomes:

```swift
    private var fieldSequence: [FormField] {
        formFieldSequence(terminal: terminal, isRepo: repoRoot != nil,
                          showWorktreeToggle: showWorktreeToggle,
                          showBase: branchIsNew,
                          isClaude: isClaude,
                          customAgent: agentChoice == customAgentSlot)
    }
```

**4c. Body.** Replace the whole `if repoRoot != nil { … }` block (worktree toggle + branch/base rows) with:

```swift
            if repoRoot != nil {
                branchRow
                if showWorktreeToggle {
                    toggleRow(.worktree, label: "Create worktree", value: $createWorktree)
                }
                if branchIsNew {
                    baseRow
                }
            }
```

**4d. Rows.** After `dirRow`, add (mirrors dirRow's mechanics; `suggestionList` is extracted in 4e):

```swift
    private var branchRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(currentBranch.map { "branch (current: \($0))" } ?? "branch",
                      text: $branchInput)
                .focused($focus, equals: .branch)
                .onSubmit { advance(from: .branch) }
                .onKeyPress(.downArrow) { step($branchSelected, in: branchEntries, 1); return .handled }
                .onKeyPress(.upArrow) { step($branchSelected, in: branchEntries, -1); return .handled }
                .onKeyPress(.tab) { acceptBranch() ? .handled : .ignored }
                .onKeyPress(.rightArrow, phases: .down) { _ in
                    branchEntries.isEmpty ? .ignored : (acceptBranch() ? .handled : .ignored)
                }
            if focus == .branch {
                suggestionList(entries: branchEntries, selected: $branchSelected) {
                    branchInput = $0
                }
                if branchIsNew {
                    Text("will create branch \"\(trimmedBranch)\"")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let path = branchWorktreePath {
                Text("opens in: \(collapseHome(path))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var baseRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(currentBranch.map { "base (default: \($0))" } ?? "base",
                      text: $baseInput)
                .focused($focus, equals: .base)
                .onSubmit { advance(from: .base) }
                .onKeyPress(.downArrow) { step($baseSelected, in: baseEntries, 1); return .handled }
                .onKeyPress(.upArrow) { step($baseSelected, in: baseEntries, -1); return .handled }
                .onKeyPress(.tab) { acceptBase() ? .handled : .ignored }
                .onKeyPress(.rightArrow, phases: .down) { _ in
                    baseEntries.isEmpty ? .ignored : (acceptBase() ? .handled : .ignored)
                }
            if focus == .base {
                suggestionList(entries: baseEntries, selected: $baseSelected) {
                    baseInput = $0
                }
            }
        }
    }
```

**4e. Shared suggestion list.** Extract from `dirRow` (which currently inlines the same VStack) into:

```swift
    /// The dir-picker's suggestion dropdown, shared by the branch/base rows:
    /// first 8 entries, highlight, click-to-pick, "… N more" tail.
    @ViewBuilder
    private func suggestionList(entries: [String], selected: Binding<Int>,
                                pick: @escaping (String) -> Void) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(entries.prefix(8).enumerated()), id: \.offset) { idx, entry in
                    Text(entry)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(idx == selected.wrappedValue
                                    ? Color.accentColor.opacity(0.2) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { selected.wrappedValue = idx; pick(entry) }
                }
                if entries.count > 8 {
                    Text("… \(entries.count - 8) more")
                        .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 6)
                }
            }
        }
    }
```

`dirRow`'s inline list block (`if focus == .dir, !dirEntries.isEmpty { … }`) becomes:

```swift
            if focus == .dir {
                suggestionList(entries: dirEntries, selected: $dirSelected) { _ in
                    _ = dirDescend()
                }
            }
```

**4f. Behavior.** Delete `dirStep` and change the dir field's arrow handlers to

```swift
                .onKeyPress(.downArrow) { step($dirSelected, in: dirEntries, 1); return .handled }
                .onKeyPress(.upArrow) { step($dirSelected, in: dirEntries, -1); return .handled }
```

then add the shared stepper and the accept helpers where `dirStep` was:

```swift
    /// ↓/↑ over a suggestion list with wrap (the TUI picker's walk).
    private func step(_ selected: Binding<Int>, in entries: [String], _ delta: Int) {
        guard !entries.isEmpty else { return }
        selected.wrappedValue = ((selected.wrappedValue + delta) % entries.count
                                 + entries.count) % entries.count
    }

    @discardableResult
    private func acceptBranch() -> Bool {
        guard focus == .branch, branchEntries.indices.contains(branchSelected)
        else { return false }
        branchInput = branchEntries[branchSelected]
        return true
    }

    @discardableResult
    private func acceptBase() -> Bool {
        guard focus == .base, baseEntries.indices.contains(baseSelected)
        else { return false }
        baseInput = baseEntries[baseSelected]
        return true
    }
```

**4g. Data refresh.** `.task(id: dir)` becomes (typed text survives a dir change; the derived state recomputes):

```swift
        .task(id: dir) {
            refreshDirEntries()
            let info = await model.gitInfo(dir)
            repoRoot = info.repoRoot
            currentBranch = info.currentBranch
            branches = info.branches
            worktrees = info.worktrees
        }
```

and add reset-on-typing modifiers next to the existing `.onChange` handlers:

```swift
        .onChange(of: branchInput) { _, _ in branchSelected = 0 }
        .onChange(of: baseInput) { _, _ in baseSelected = 0 }
```

**4h. Submit.** Replace the `var worktree: WorktreeSpec?` block in `submit()` with:

```swift
        var worktree: WorktreeSpec?
        if repoRoot != nil {
            if branchIsNew {
                if let err = validateBranch(trimmedBranch) { error = err; return }
                let trimmedBase = baseInput.trimmingCharacters(in: .whitespaces)
                if !trimmedBase.isEmpty && !branches.contains(trimmedBase) {
                    error = "base branch not found: \(trimmedBase)"; return
                }
            }
            worktree = branchPlan(input: branchInput, current: currentBranch,
                                  branches: branches, worktrees: worktrees,
                                  createWorktree: createWorktree, base: baseInput)
        }
```

- [ ] **Step 5: Build + tests**

Run: `swift build && swift test --filter DirBrowseTests && swift test`
Expected: all green.

- [ ] **Step 6: Smoke** — restart the daemon and run the app:

```bash
pkill -f coveyd; rm -f ~/.covey/coveyd.sock
swift run covey
```

⌘N in a repo with many branches (this repo qualifies) and verify:
1. No vertical one-letter-per-line branch chips anywhere.
2. Branch field: empty with `branch (current: …)` placeholder; focusing shows the branch list; typing filters it; ↓/↑/Tab/→/click work like the dir picker.
3. Typing a fresh name shows `will create branch "…"`, the "Create worktree" checkbox, and the base field.
4. Picking a branch that has a worktree hides the checkbox and shows `opens in: …`; creating opens the session in that worktree.
5. Existing branch + unchecked checkbox → session in the repo root on that branch; checked → session in `.worktrees/<branch>`.
6. Enter walks name → dir → terminal → branch → (checkbox) → (base) → agent → …; ⇧Enter creates; Esc cancels.

- [ ] **Step 7: Hand the commit to the user**

```bash
git add Sources/covey/Views/NewSessionSheet.swift Sources/covey/Views/Sheets.swift Sources/covey/DirBrowse.swift Tests/CoveyAppTests/DirBrowseTests.swift
git commit -m "feat(covey): typeahead branch picker + checkout-in-root create flow"
```
