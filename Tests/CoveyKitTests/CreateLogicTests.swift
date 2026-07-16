import XCTest
@testable import CoveyKit

final class CreateLogicTests: XCTestCase {
    func testEffortLevels() {
        XCTAssertEqual(effortLevels(model: "opus"), ["auto", "low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(effortLevels(model: "sonnet"), ["auto", "low", "medium", "high", "max"])
        XCTAssertEqual(effortLevels(model: "haiku"), ["auto"])
        XCTAssertEqual(effortLevels(model: nil), ["auto"])
    }

    func testComposeAgentArgv() {
        XCTAssertEqual(composeAgentArgv(agent: "claude", model: nil, effort: nil), ["claude"])
        XCTAssertEqual(composeAgentArgv(agent: "claude", model: "opus", effort: nil),
                       ["claude", "--model", "opus"])
        XCTAssertEqual(composeAgentArgv(agent: "claude", model: "opus", effort: "max"),
                       ["claude", "--model", "opus", "--effort", "max"])
        XCTAssertEqual(composeAgentArgv(agent: "my-wrapper --verbose", model: nil, effort: nil),
                       ["my-wrapper", "--verbose"],
                       "custom agent field is binary + flags, split on whitespace")
    }

    func testComposeAgentArgvDoesNotSplitInjectedShellMetacharacters() {
        let argv = composeAgentArgv(agent: "claude; rm -rf ~", model: nil, effort: nil)
        XCTAssertEqual(argv, ["claude;", "rm", "-rf", "~"])
        XCTAssertTrue(argv[0].hasSuffix(";"),
                      "the semicolon stays glued to the first token — there is no shell " +
                      "to interpret it as a command separator, so execvp fails to resolve " +
                      "a binary literally named 'claude;' instead of running a second command")
    }

    func testValidateAgent() {
        XCTAssertNil(validateAgent("claude"))
        XCTAssertNotNil(validateAgent(""))
        XCTAssertNotNil(validateAgent("   "))
    }

    func testComposeLaunchTerminalUsesShell() {
        let spec = CreateSpec(dir: "/w", agent: "claude", terminal: true)
        let (cmd, label, resume) = composeLaunch(spec: spec, uuid: "u-1")
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
        XCTAssertEqual(cmd, .argv([shell]))
        XCTAssertEqual(label, (shell as NSString).lastPathComponent)
        XCTAssertNil(resume)
    }

    func testComposeLaunchClaudeInjectsSessionId() {
        let spec = CreateSpec(dir: "/w", agent: "claude", model: "opus")
        let (cmd, label, resume) = composeLaunch(spec: spec, uuid: "abc")
        XCTAssertEqual(cmd, .argv(["claude", "--model", "opus", "--session-id", "abc"]))
        XCTAssertEqual(label, "claude")
        XCTAssertEqual(resume, "claude --resume abc")
    }

    func testComposeLaunchResumeFallsBackToFreshSession() {
        // claude writes the conversation file only after the first message, so
        // resuming a never-used session dies with "No conversation found" —
        // the launch command falls back to a fresh claude with the SAME id.
        // This whole string is covey-generated (the uuid), never user input,
        // so it stays on the shell path (see LaunchCommand.shellString).
        let spec = CreateSpec(dir: "/w", agent: "claude", resume: "claude --resume abc")
        let (cmd, _, resume) = composeLaunch(spec: spec, uuid: nil)
        XCTAssertEqual(cmd, .shellString("claude --resume abc || claude --session-id abc"))
        XCTAssertEqual(resume, "claude --resume abc",
                       "the SAVED command stays canonical — re-wrapped at each relaunch")
    }

    func testResumeLaunchCommandLeavesForeignCommandsAlone() {
        XCTAssertEqual(resumeLaunchCommand("codex --resume abc"), "codex --resume abc")
        XCTAssertEqual(resumeLaunchCommand("claude --continue"), "claude --continue")
    }

    func testComposeLaunchNonClaudeHasNoResume() {
        let spec = CreateSpec(dir: "/w", agent: "codex")
        let (cmd, _, resume) = composeLaunch(spec: spec, uuid: "abc")
        XCTAssertEqual(cmd, .argv(["codex"]))
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

    func testValidateBranch() {
        XCTAssertNil(validateBranch("feature/x"))
        XCTAssertNotNil(validateBranch(""))
        XCTAssertNotNil(validateBranch("-oops"))
        XCTAssertNotNil(validateBranch("/abs"))
        XCTAssertNotNil(validateBranch("a/../b"))
        XCTAssertNotNil(validateBranch("."))
    }

    func testExpandTilde() {
        XCTAssertEqual(expandTilde("~/x"),
                       FileManager.default.homeDirectoryForCurrentUser.path + "/x")
        XCTAssertEqual(expandTilde("/abs/x"), "/abs/x")
    }

    func testCollapseHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(collapseHome(home + "/projects"), "~/projects")
        XCTAssertEqual(collapseHome(home), "~")
        XCTAssertEqual(collapseHome("/opt/x"), "/opt/x")
        XCTAssertEqual(collapseHome(home + "ster/x"), home + "ster/x",
                       "prefix must match a path segment, not a substring")
    }

    func testWorktreeSpecRoundTrip() throws {
        let enc = JSONEncoder(); let dec = JSONDecoder()
        for spec: WorktreeSpec in [.new(branch: "b", base: "main"), .existing(branch: "b")] {
            let back = try dec.decode(WorktreeSpec.self, from: enc.encode(spec))
            XCTAssertEqual(back, spec)
        }
    }
}
