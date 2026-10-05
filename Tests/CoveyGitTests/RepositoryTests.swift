import XCTest
@testable import CoveyGit

final class RepositoryTests: XCTestCase {
    /// The policy covey passes in production (CoveyKit.protectedBranches).
    private let protected = ["main", "master", "develop", "dev"]

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
        guard p.terminationStatus == 0 else { throw GitError("sh failed: \(cmd)") }
    }

    func testRepoRootAndBranches() throws {
        let root = Repository(at: repo).toplevel()
        XCTAssertNotNil(root)
        XCTAssertTrue(root!.hasSuffix(URL(fileURLWithPath: repo).lastPathComponent))
        XCTAssertNil(Repository(at: NSTemporaryDirectory()).toplevel())
        XCTAssertEqual(Repository(at: repo).currentBranch(), "main")
        XCTAssertEqual(Repository(at: repo).localBranches(), ["main"])
        XCTAssertTrue(Repository(at: repo).branchExists("main"))
        XCTAssertFalse(Repository(at: repo).branchExists("nope"))
    }

    func testPrepareWorktreeNewBranch() throws {
        let wt = "\(repo)/.worktrees/feat"
        try Repository(at: repo).ensureGitignore(entry: ".worktrees/")
        try Repository(at: repo).addWorktree(at: wt, newBranch: "feat", base: "main")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt))
        XCTAssertTrue(Repository(at: repo).branchExists("feat"))
        let ignore = try String(contentsOfFile: "\(repo)/.gitignore", encoding: .utf8)
        XCTAssertTrue(ignore.contains(".worktrees/"))
        // idempotent gitignore
        try Repository(at: repo).ensureGitignore(entry: ".worktrees/")
        let again = try String(contentsOfFile: "\(repo)/.gitignore", encoding: .utf8)
        XCTAssertEqual(ignore, again)
        // duplicate branch -> error
        XCTAssertThrowsError(try Repository(at: repo).addWorktree(
            at: "\(repo)/.worktrees/feat2", newBranch: "feat", base: "main"))
        XCTAssertEqual(Repository(at: repo).worktreePath(forBranch: "feat").map {
            URL(fileURLWithPath: $0).lastPathComponent
        }, "feat")
    }

    func testPrepareWorktreeExistingAndRemove() throws {
        try sh("git -C '\(repo)' branch other")
        let wt = "\(repo)/.worktrees/other"
        try Repository(at: repo).addWorktree(at: wt, existingBranch: "other")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt))
        try Repository(at: repo).removeWorktree(at: wt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt))
        XCTAssertThrowsError(try Repository(at: repo).addWorktree(
            at: "\(repo)/.worktrees/ghost", existingBranch: "ghost"))
    }

    func testStaleWorktreePathIsCleared() throws {
        let wt = "\(repo)/.worktrees/feat"
        // an orphan non-empty dir at the target path, unknown to git
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        try "junk".write(toFile: "\(wt)/junk.txt", atomically: true, encoding: .utf8)
        try Repository(at: repo).addWorktree(at: wt, newBranch: "feat", base: "main")
        XCTAssertTrue(Repository(at: repo).branchExists("feat"), "orphan dir must not block the add")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(wt)/junk.txt"))
    }

    func testWorktreesMap() throws {
        var map = Repository(at: repo).worktrees()
        XCTAssertEqual(Array(map.keys), ["main"], "main worktree is included")
        XCTAssertTrue(map["main"]!.hasSuffix(URL(fileURLWithPath: repo).lastPathComponent))
        try sh("git -C '\(repo)' branch other")
        try Repository(at: repo).addWorktree(at: "\(repo)/.worktrees/other",
                                             existingBranch: "other")
        try sh("git -C '\(repo)' worktree add --detach '\(repo)/.worktrees/loose'")
        map = Repository(at: repo).worktrees()
        XCTAssertEqual(map.keys.sorted(), ["main", "other"], "detached worktree skipped")
        XCTAssertTrue(map["other"]!.hasSuffix(".worktrees/other"))
        XCTAssertEqual(Repository(at: NSTemporaryDirectory()).worktrees(), [:])
    }

    func testPrimaryWorktreeDetectionRejectsLinkedWorktree() throws {
        let linked = "\(repo)/.worktrees/linked"
        try sh("git -C '\(repo)' worktree add -q -b linked '\(linked)' main")

        XCTAssertTrue(try Repository(at: repo).isPrimaryWorktree())
        XCTAssertFalse(try Repository(at: linked).isPrimaryWorktree())
        XCTAssertThrowsError(try Repository(at: NSTemporaryDirectory()).isPrimaryWorktree())
    }

    func testCreateBranch() throws {
        try Repository(at: repo).createBranch("feat", from: "main")
        XCTAssertEqual(Repository(at: repo).currentBranch(), "feat", "created AND checked out")
        XCTAssertThrowsError(try Repository(at: repo).createBranch("feat", from: "main"),
                             "duplicate branch")
        XCTAssertThrowsError(try Repository(at: repo).createBranch("x", from: "nope"),
                             "unknown base")
    }

    func testReadGitInfoSeparatesUnstagedStagedAndUntracked() throws {
        try ".ignored\n".write(
            toFile: "\(repo)/.gitignore", atomically: true, encoding: .utf8
        )
        try "base\n".write(
            toFile: "\(repo)/tracked.txt", atomically: true, encoding: .utf8
        )
        try sh("git -C '\(repo)' add .gitignore tracked.txt && git -C '\(repo)' -c user.email=t@t -c user.name=t commit -q -m tracked")

        try "base\nstaged\n".write(
            toFile: "\(repo)/tracked.txt", atomically: true, encoding: .utf8
        )
        try sh("git -C '\(repo)' add tracked.txt")
        try "base\nstaged\nunstaged\n".write(
            toFile: "\(repo)/tracked.txt", atomically: true, encoding: .utf8
        )
        try "new".write(
            toFile: "\(repo)/untracked.txt", atomically: true, encoding: .utf8
        )
        try "ignored".write(
            toFile: "\(repo)/.ignored", atomically: true, encoding: .utf8
        )

        let info = try XCTUnwrap(Repository(at: repo).workingTreeSummary())
        XCTAssertEqual(info.unstaged, DiffTotals(files: 1, added: 1, removed: 0))
        XCTAssertEqual(info.staged, DiffTotals(files: 1, added: 1, removed: 0))
        XCTAssertEqual(info.untracked, 1)
    }

    func testReadGitInfoCountsBinaryChangeWithZeroLineDelta() throws {
        try Data([0, 1, 2]).write(to: URL(fileURLWithPath: "\(repo)/binary.dat"))
        try sh("git -C '\(repo)' add binary.dat && git -C '\(repo)' -c user.email=t@t -c user.name=t commit -q -m binary")
        try Data([0, 1, 3]).write(to: URL(fileURLWithPath: "\(repo)/binary.dat"))

        let info = try XCTUnwrap(Repository(at: repo).workingTreeSummary())
        XCTAssertEqual(info.unstaged, DiffTotals(files: 1, added: 0, removed: 0))
    }

    func testParseNumstatHandlesBinaryAndRenamePathRecords() {
        let text = "1\t2\tfile.swift\0"
            + "-\t-\tbinary.dat\0"
            + "0\t0\t\0old\0new\0"
        XCTAssertEqual(
            Numstat.totals(text),
            DiffTotals(files: 3, added: 1, removed: 2)
        )
    }

    func testReadGitInfo() throws {
        try "line\n".write(toFile: "\(repo)/f.txt", atomically: true, encoding: .utf8)
        try sh("git -C '\(repo)' add f.txt && git -C '\(repo)' -c user.email=t@t -c user.name=t commit -q -m f")
        var info = Repository(at: repo).workingTreeSummary()
        XCTAssertEqual(info?.branch, "main")
        XCTAssertEqual(info?.unstaged.added, 0)
        try "line\nmore\n".write(toFile: "\(repo)/f.txt", atomically: true, encoding: .utf8)
        info = Repository(at: repo).workingTreeSummary()
        XCTAssertEqual(info?.unstaged.added, 1)
        XCTAssertNil(Repository(at: NSTemporaryDirectory()).workingTreeSummary())
    }

    func testRequireCleanWorktreeIgnoresStatusPreferenceAndFailsClosed() throws {
        try sh("git -C '\(repo)' config status.showUntrackedFiles no")
        try "untracked".write(
            toFile: "\(repo)/untracked.txt", atomically: true, encoding: .utf8
        )

        XCTAssertThrowsError(try Repository(at: repo).requireClean()) { error in
            XCTAssertTrue("\(error)".contains("uncommitted changes"))
        }
        XCTAssertThrowsError(try Repository(at: NSTemporaryDirectory()).requireClean())
    }

    func testPromoteWorktreeMovesDirtyChanges() throws {
        let wt = "\(repo)/.worktrees/feat"
        try Repository(at: repo).addWorktree(at: wt, newBranch: "feat", base: "main")
        try "wip".write(toFile: "\(wt)/wip.txt", atomically: true, encoding: .utf8)
        try Repository(at: repo).promoteWorktree(at: wt, branch: "feat")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt), "worktree removed")
        XCTAssertEqual(Repository(at: repo).currentBranch(), "feat", "branch checked out in root")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(repo)/wip.txt"),
                      "uncommitted file travelled via the stash")
    }

    func testDeleteBranchMergedOnly() throws {
        try sh("git -C '\(repo)' branch merged-b")
        try Repository(at: repo).deleteBranch("merged-b", protected: protected)
        XCTAssertFalse(Repository(at: repo).branchExists("merged-b"))
        // an unmerged branch refuses -d
        try sh("git -C '\(repo)' checkout -q -b unmerged && touch '\(repo)/u.txt' && git -C '\(repo)' add u.txt && git -C '\(repo)' -c user.email=t@t -c user.name=t commit -q -m u && git -C '\(repo)' checkout -q main")
        XCTAssertThrowsError(try Repository(at: repo).deleteBranch("unmerged", protected: protected))
    }

    func testProtectedBranchesCannotBeDeletedInSafeOrForceMode() throws {
        for branch in ["master", "develop", "dev"] {
            try sh("git -C '\(repo)' branch '\(branch)'")
        }
        for branch in ["main", "master", "develop", "dev"] {
            for force in [false, true] {
                XCTAssertThrowsError(
                    try Repository(at: repo).deleteBranch(branch, force: force, protected: protected)
                ) { error in
                    XCTAssertTrue("\(error)".contains("protected"))
                }
                XCTAssertTrue(Repository(at: repo).branchExists(branch))
            }
        }
    }

    func testForceModeDeletesCleanUnmergedLocalBranch() throws {
        try sh("git -C '\(repo)' checkout -q -b feat && echo work > '\(repo)/work.txt' && git -C '\(repo)' add work.txt && git -C '\(repo)' -c user.email=t@t -c user.name=t commit -q -m work && git -C '\(repo)' checkout -q main")

        XCTAssertThrowsError(
            try Repository(at: repo).deleteBranch("feat", force: false, protected: protected)
        )
        XCTAssertTrue(Repository(at: repo).branchExists("feat"))

        try Repository(at: repo).deleteBranch("feat", force: true, protected: protected)
        XCTAssertFalse(Repository(at: repo).branchExists("feat"))
    }

    func testConditionalForceDeletionRejectsAdvancedBranchTip() throws {
        try sh("git -C '\(repo)' checkout -q -b feat && echo one > '\(repo)/work.txt' && git -C '\(repo)' add work.txt && git -C '\(repo)' -c user.email=t@t -c user.name=t commit -q -m one && git -C '\(repo)' checkout -q main")
        let expectedOID = try XCTUnwrap(Repository(at: repo).localBranchOID("feat"))
        try sh("git -C '\(repo)' checkout -q feat && echo two >> '\(repo)/work.txt' && git -C '\(repo)' add work.txt && git -C '\(repo)' -c user.email=t@t -c user.name=t commit -q -m two && git -C '\(repo)' checkout -q main")

        XCTAssertThrowsError(try Repository(at: repo).deleteBranch(
            "feat", force: true, expectedOID: expectedOID, protected: protected
        ))
        XCTAssertNotEqual(try Repository(at: repo).localBranchOID("feat"), expectedOID)
    }

    func testPostDeleteWorktreeDetectionRestoresExpectedBranchTip() throws {
        let worktree = "\(repo)/.worktrees/feat"
        try Repository(at: repo).addWorktree(
            at: worktree, newBranch: "feat", base: "main"
        )
        let expectedOID = try XCTUnwrap(Repository(at: repo).localBranchOID("feat"))
        try GitRunner.run(
            in: repo, ["update-ref", "-d", "refs/heads/feat", expectedOID]
        )
        XCTAssertNil(try Repository(at: repo).localBranchOID("feat"))

        XCTAssertThrowsError(try Repository(at: repo).verifyDeletedBranchNotCheckedOut(
            branch: "feat", expectedOID: expectedOID
        ))

        XCTAssertEqual(try Repository(at: repo).localBranchOID("feat"), expectedOID)
        XCTAssertEqual(Repository(at: worktree).currentBranch(), "feat")
    }

    func testSwitchAndDeleteChecksOutDestinationThenDeletesExpectedBranch() throws {
        try sh("git -C '\(repo)' checkout -q -b feat && echo work > '\(repo)/work.txt' && git -C '\(repo)' add work.txt && git -C '\(repo)' -c user.email=t@t -c user.name=t commit -q -m work")

        try Repository(at: repo).switchAndDeleteBranch(
            expected: "feat", checkout: "main", protected: protected
        )

        XCTAssertEqual(Repository(at: repo).currentBranch(), "main")
        XCTAssertFalse(Repository(at: repo).branchExists("feat"))
    }

    func testSwitchAndDeleteSupportsRetryAfterCheckout() throws {
        try sh("git -C '\(repo)' branch feat")

        try Repository(at: repo).switchAndDeleteBranch(
            expected: "feat", checkout: "main", protected: protected
        )

        XCTAssertEqual(Repository(at: repo).currentBranch(), "main")
        XCTAssertFalse(Repository(at: repo).branchExists("feat"))
    }

    func testSwitchAndDeleteRetrySucceedsWhenSourceIsAlreadyAbsent() throws {
        XCTAssertNoThrow(try Repository(at: repo).switchAndDeleteBranch(
            expected: "already-gone", checkout: "main", protected: protected
        ))
        XCTAssertEqual(Repository(at: repo).currentBranch(), "main")
    }

    func testSwitchAndDeleteRejectsDirtyAndMissingDestination() throws {
        try sh("git -C '\(repo)' branch feat")
        try "dirty".write(
            toFile: "\(repo)/dirty.txt", atomically: true, encoding: .utf8
        )
        XCTAssertThrowsError(try Repository(at: repo).switchAndDeleteBranch(
            expected: "feat", checkout: "main", protected: protected
        ))
        try FileManager.default.removeItem(atPath: "\(repo)/dirty.txt")
        XCTAssertThrowsError(try Repository(at: repo).switchAndDeleteBranch(
            expected: "feat", checkout: "missing", protected: protected
        ))
    }

    func testSwitchAndDeleteRejectsStaleCurrentBranch() throws {
        try sh("git -C '\(repo)' branch feat")
        try sh("git -C '\(repo)' checkout -q -b other")

        XCTAssertThrowsError(try Repository(at: repo).switchAndDeleteBranch(
            expected: "feat", checkout: "main", protected: protected
        ))
        XCTAssertEqual(Repository(at: repo).currentBranch(), "other")
        XCTAssertTrue(Repository(at: repo).branchExists("feat"))
    }

    func testSwitchAndDeleteRejectsDestinationInAnotherWorktree() throws {
        try sh("git -C '\(repo)' checkout -q -b feat")
        let other = "\(repo)/.worktrees/other"
        try sh("git -C '\(repo)' worktree add -q -b other '\(other)' main")

        XCTAssertThrowsError(try Repository(at: repo).switchAndDeleteBranch(
            expected: "feat", checkout: "other", protected: protected
        ))
        XCTAssertEqual(Repository(at: repo).currentBranch(), "feat")
        XCTAssertTrue(Repository(at: repo).branchExists("feat"))
    }

    func testListMergedBranches() throws {
        try sh("git -C '\(repo)' branch merged-b")
        let merged = Repository(at: repo).mergedBranches()
        XCTAssertTrue(merged.contains("merged-b"))
        XCTAssertFalse(merged.contains("main"), "current branch excluded")
    }

    func testSeedWorktreeIgnoredCopiesIgnoredSkipsHeavy() throws {
        // .gitignore selects the ignored paths; commit it so the tree is clean.
        try """
        .env
        config/
        node_modules/
        .worktrees/
        """.write(toFile: "\(repo)/.gitignore", atomically: true, encoding: .utf8)
        try sh("git -C '\(repo)' add .gitignore && git -C '\(repo)' -c user.email=t@t -c user.name=t commit -q -m ignore")
        // ignored files present in the repo working tree
        try "SECRET=1".write(toFile: "\(repo)/.env", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: "\(repo)/config", withIntermediateDirectories: true)
        try "k=v".write(toFile: "\(repo)/config/local.json", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: "\(repo)/node_modules", withIntermediateDirectories: true)
        try "junk".write(toFile: "\(repo)/node_modules/lib.js", atomically: true, encoding: .utf8)

        let wt = "\(repo)/.worktrees/feat"
        try Repository(at: repo).addWorktree(at: wt, newBranch: "feat", base: "main")
        Repository(at: repo).seedIgnoredFiles(into: wt)

        XCTAssertEqual(try? String(contentsOfFile: "\(wt)/.env", encoding: .utf8), "SECRET=1",
                       "ignored file copied")
        XCTAssertEqual(try? String(contentsOfFile: "\(wt)/config/local.json", encoding: .utf8), "k=v",
                       "ignored dir copied recursively")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(wt)/node_modules"),
                       "heavy dir skipped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(wt)/.worktrees"),
                       "the .worktrees layer is never seeded into itself")
    }
}
