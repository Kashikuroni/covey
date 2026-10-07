import XCTest
@testable import CoveydCore
import CoveyGit
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
        guard p.terminationStatus == 0 else { throw GitError("sh failed: \(cmd)") }
    }

    func testPlainAgentPrepared() throws {
        let p = try CreateService.prepare(CreateSpec(dir: "/tmp", agent: "sh"))
        XCTAssertEqual(p.finalDir, "/tmp")
        XCTAssertEqual(p.argv, ["/bin/sh"], "resolved to an absolute path, no shell wrapper")
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
        guard let modelIdx = p.argv.firstIndex(of: "--model"),
              let sessionIdx = p.argv.firstIndex(of: "--session-id") else {
            return XCTFail("missing flags in argv: \(p.argv)")
        }
        XCTAssertEqual(p.argv[modelIdx + 1], "opus")
        XCTAssertFalse(p.argv[sessionIdx + 1].isEmpty, "a uuid follows --session-id")
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
        XCTAssertTrue(Repository(at: repo).branchExists("feat"))
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
        XCTAssertEqual(Repository(at: repo).currentBranch(), "main", "no switch happened")
    }

    func testCheckoutBranchWithWorktreeOpensIt() throws {
        try sh("git -C '\(repo)' branch other")
        try sh("git -C '\(repo)' worktree add '\(repo)/.worktrees/other' other")
        let p = try CreateService.prepare(CreateSpec(
            dir: repo, agent: "sh", worktree: .checkout(branch: "other")))
        XCTAssertTrue(p.finalDir.hasSuffix(".worktrees/other"))
        XCTAssertNotNil(p.worktreeRepo, "existing worktree session is removable")
        XCTAssertEqual(Repository(at: repo).currentBranch(), "main", "root untouched")
    }

    func testCheckoutSwitchesRootBranch() throws {
        try sh("git -C '\(repo)' branch other")
        let p = try CreateService.prepare(CreateSpec(
            dir: repo, agent: "sh", worktree: .checkout(branch: "other")))
        XCTAssertNil(p.worktreeRepo)
        XCTAssertEqual(URL(fileURLWithPath: p.finalDir).lastPathComponent,
                       URL(fileURLWithPath: repo).lastPathComponent)
        XCTAssertEqual(Repository(at: repo).currentBranch(), "other", "switched in root")
    }

    func testCheckoutNewCreatesBranchInRoot() throws {
        let p = try CreateService.prepare(CreateSpec(
            dir: repo, agent: "sh", worktree: .checkoutNew(branch: "feat", base: "main")))
        XCTAssertNil(p.worktreeRepo)
        XCTAssertEqual(Repository(at: repo).currentBranch(), "feat")
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

    func testWorktreeNewSeedsIgnoredFiles() throws {
        try """
        .env
        .worktrees/
        """.write(toFile: "\(repo)/.gitignore", atomically: true, encoding: .utf8)
        try sh("git -C '\(repo)' add .gitignore && git -C '\(repo)' -c user.email=t@t -c user.name=t commit -q -m ignore")
        try "SECRET=1".write(toFile: "\(repo)/.env", atomically: true, encoding: .utf8)

        let p = try CreateService.prepare(CreateSpec(
            dir: repo, agent: "sh",
            worktree: .new(branch: "feat", base: "main")))

        XCTAssertEqual(try? String(contentsOfFile: "\(p.finalDir)/.env", encoding: .utf8),
                       "SECRET=1", "the new worktree carries the ignored .env")
    }

    // MARK: - progress stages + base-branch pull

    /// Bare "origin" + a clone of it with a `dev` branch tracking origin/dev.
    /// Returns (repo, origin, dev tip OID at push time).
    private func makeClonedRepo() throws -> (repo: String, origin: String, devTip: String) {
        let origin = "\(NSTemporaryDirectory())covey-cs-origin-\(UInt32.random(in: 0..<UInt32.max)).git"
        let clone = "\(NSTemporaryDirectory())covey-cs-clone-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: clone, withIntermediateDirectories: true)
        try sh("git init -q --bare '\(origin)'")
        try sh("git clone -q '\(origin)' '\(clone)'")
        try sh("git -C '\(clone)' switch -q -c dev")
        try sh("git -C '\(clone)' -c user.email=t@t -c user.name=t commit --allow-empty -q -m one")
        try sh("git -C '\(clone)' push -q -u origin dev")
        try sh("git -C '\(clone)' switch -q -c main")
        let tip = try Repository(at: clone).localBranchOID("dev") ?? ""
        return (clone, origin, tip)
    }

    /// Advances the bare origin's dev by one empty commit, returns its OID.
    private func advanceOriginDev(origin: String, parent: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", """
            set -e
            tree=$(git -C '\(origin)' rev-parse \(parent)^{tree})
            new=$(git -C '\(origin)' -c user.email=t@t -c user.name=t commit-tree $tree -p \(parent) -m ahead)
            git -C '\(origin)' update-ref refs/heads/dev $new
            printf %s "$new"
            """]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw GitError("commit-tree failed") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testWorktreeNewEmitsStagesInOrder() throws {
        var stages: [CreateStage] = []
        _ = try CreateService.prepare(CreateSpec(
            dir: repo, agent: "sh",
            worktree: .new(branch: "feat", base: "main"))) { stages.append($0) }
        XCTAssertEqual(stages, [.updatingBase(branch: "main"), .creatingWorktree,
                                .seedingFiles])
    }

    func testWorktreeExistingEmitsWorktreeStagesOnly() throws {
        try sh("git -C '\(repo)' branch other")
        var stages: [CreateStage] = []
        _ = try CreateService.prepare(CreateSpec(
            dir: repo, agent: "sh",
            worktree: .existing(branch: "other"))) { stages.append($0) }
        XCTAssertEqual(stages, [.creatingWorktree, .seedingFiles])
    }

    func testCheckoutNewEmitsBaseStageOnly() throws {
        var stages: [CreateStage] = []
        _ = try CreateService.prepare(CreateSpec(
            dir: repo, agent: "sh",
            worktree: .checkoutNew(branch: "feat", base: "main"))) { stages.append($0) }
        XCTAssertEqual(stages, [.updatingBase(branch: "main")])
    }

    func testWorktreeNewForksFromFetchedUpstream() throws {
        let (clone, origin, tip) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(atPath: clone)
                try? FileManager.default.removeItem(atPath: origin) }
        let ahead = try advanceOriginDev(origin: origin, parent: tip)

        _ = try CreateService.prepare(CreateSpec(
            dir: clone, agent: "sh",
            worktree: .new(branch: "feat", base: "dev")))

        XCTAssertEqual(try Repository(at: clone).localBranchOID("feat"), ahead,
                       "feat forked from the fetched dev tip, not the stale local one")
    }

    func testWorktreeNewDivergedBaseFallsBackToLocal() throws {
        let (clone, origin, tip) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(atPath: clone)
                try? FileManager.default.removeItem(atPath: origin) }
        _ = try advanceOriginDev(origin: origin, parent: tip)
        try sh("git -C '\(clone)' switch -q dev && git -C '\(clone)' -c user.email=t@t -c user.name=t commit --allow-empty -q -m local && git -C '\(clone)' switch -q main")
        let localDev = try Repository(at: clone).localBranchOID("dev")

        _ = try CreateService.prepare(CreateSpec(
            dir: clone, agent: "sh",
            worktree: .new(branch: "feat", base: "dev")))

        XCTAssertEqual(try Repository(at: clone).localBranchOID("feat"), localDev,
                       "a refused pull leaves the base alone; feat forks from local dev")
    }

    func testCheckoutNewAlsoPullsBase() throws {
        let (clone, origin, tip) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(atPath: clone)
                try? FileManager.default.removeItem(atPath: origin) }
        let ahead = try advanceOriginDev(origin: origin, parent: tip)

        _ = try CreateService.prepare(CreateSpec(
            dir: clone, agent: "sh",
            worktree: .checkoutNew(branch: "feat", base: "dev")))

        XCTAssertEqual(try Repository(at: clone).localBranchOID("feat"), ahead,
                       "the in-root new branch also forks from the fetched tip")
    }
}
