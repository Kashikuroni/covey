import XCTest
@testable import CoveydCore
import CoveyKit

final class CreateServiceTests: XCTestCase {
    private var repo = ""

    override func setUpWithError() throws {
        repo = "\(NSTemporaryDirectory())covey-create-\(UInt32.random(in: 0..<UInt32.max))"
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

    func testPlainAgentPrepared() throws {
        let p = try CreateService.prepare(CreateSpec(dir: "/tmp", agent: "sh"))
        XCTAssertEqual(p.finalDir, "/tmp")
        XCTAssertEqual(Array(p.argv.prefix(2)), ["/bin/sh", "-c"])
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
        XCTAssertTrue(cmd.contains("--model opus"), cmd)
        XCTAssertTrue(p.resumeCmd?.hasPrefix("claude --resume ") == true)
    }

    func testResumeRunsSavedCommand() throws {
        let p = try CreateService.prepare(CreateSpec(dir: "/tmp", agent: "claude",
                                                     resume: "claude --resume abc"))
        let cmd = p.argv.last ?? ""
        XCTAssertTrue(cmd.contains("--resume abc"), cmd)
        XCTAssertTrue(cmd.hasSuffix("|| claude --session-id abc"),
                      "never-used conversation falls back to a fresh session: \(cmd)")
        XCTAssertEqual(p.resumeCmd, "claude --resume abc")
    }

    func testWorktreeNewBranch() throws {
        let p = try CreateService.prepare(CreateSpec(
            dir: repo, agent: "sh",
            worktree: .new(branch: "feat", base: "main")))
        XCTAssertTrue(p.finalDir.hasSuffix(".worktrees/feat"))
        XCTAssertNotNil(p.worktreeRepo)
        XCTAssertTrue(GitOps.branchExists(repo, "feat"))
    }

    func testWorktreeExistingCheckedOutInRoot() throws {
        // current branch (main) is checked out in the root -> plain session there
        let p = try CreateService.prepare(CreateSpec(
            dir: repo, agent: "sh", worktree: .existing(branch: "main")))
        XCTAssertNil(p.worktreeRepo, "root checkout is not a removable worktree")
        XCTAssertEqual(URL(fileURLWithPath: p.finalDir).lastPathComponent,
                       URL(fileURLWithPath: repo).lastPathComponent)
    }

    func testWorktreeExistingUncheckedBranchGetsWorktree() throws {
        try sh("git -C '\(repo)' branch other")
        let p = try CreateService.prepare(CreateSpec(
            dir: repo, agent: "sh", worktree: .existing(branch: "other")))
        XCTAssertTrue(p.finalDir.hasSuffix(".worktrees/other"))
        XCTAssertNotNil(p.worktreeRepo)
    }

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

    func testWorktreeNotARepoThrows() {
        XCTAssertThrowsError(try CreateService.prepare(CreateSpec(
            dir: NSTemporaryDirectory(), agent: "sh", worktree: .existing(branch: "main"))))
    }
}
