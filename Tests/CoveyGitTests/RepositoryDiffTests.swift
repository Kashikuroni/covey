import XCTest
@testable import CoveyGit

final class RepositoryDiffTests: XCTestCase {
    private var repo: TestRepo!
    private var git: Repository { Repository(at: repo.path) }

    override func setUpWithError() throws { repo = try TestRepo() }
    override func tearDown() { repo.remove() }

    private func byPath(_ state: ComparisonState) -> [String: ChangedFile] {
        Dictionary(uniqueKeysWithValues: state.files.map { ($0.path, $0) })
    }

    func testDefaultBasePrefersMainThenMasterThenOriginHead() throws {
        XCTAssertEqual(git.defaultBase(), "main")
        try repo.sh("git -C '\(repo.path)' branch -m main master")
        XCTAssertEqual(git.defaultBase(), "master")
        try repo.sh("git -C '\(repo.path)' branch -m master trunk")
        XCTAssertNil(git.defaultBase())
        try repo.sh("git -C '\(repo.path)' update-ref refs/remotes/origin/trunk HEAD && git -C '\(repo.path)' symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk")
        XCTAssertEqual(git.defaultBase(), "origin/trunk")
    }

    /// `origin/HEAD` can point at a branch that is gone; that is no base.
    func testDefaultBaseIgnoresDanglingOriginHead() throws {
        try repo.sh("git -C '\(repo.path)' branch -m main trunk")
        try repo.sh("git -C '\(repo.path)' symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone")
        XCTAssertNil(git.defaultBase())
    }

    /// A user's `diff.suppressBlankEmpty=true` must not shift line numbers after a blank line.
    func testDiffNumbersSurviveSuppressBlankEmptyConfig() throws {
        try repo.sh("git -C '\(repo.path)' config diff.suppressBlankEmpty true")
        try repo.write("f.txt", "a\nb\n\nc\nd\n")
        try repo.commitAll("base")
        try repo.write("f.txt", "a\nb\n\nc\nD\n")
        let comparison = GitComparison(base: "main")
        let state = try git.changes(in: comparison)
        let file = try XCTUnwrap(state.files.first)

        let diff = try git.diff(of: file, in: comparison, mergeBase: state.mergeBase)
        XCTAssertEqual(diff.hunks.count, 1)
        // Three lines of context: the blank line (new line 3) is inside the hunk.
        XCTAssertEqual(diff.hunks[0].lines.map(\.text), ["b", "", "c", "d", "D"])
        XCTAssertEqual(diff.hunks[0].lines.map(\.newNumber), [2, 3, 4, nil, 5])

        let full = try git.diff(of: file, in: comparison, mergeBase: state.mergeBase, fullFile: true)
        XCTAssertEqual(full.hunks.flatMap(\.lines).compactMap(\.newNumber), [1, 2, 3, 4, 5])
        XCTAssertEqual(full.hunks.flatMap(\.lines).filter { $0.kind == .added }.first?.newNumber, 5)
    }

    func testWorkingTreeChangesCoverEveryKind() throws {
        try repo.write("a.txt", "one\n")
        try repo.write("b.txt", "bee\n")
        try repo.write("c.txt", (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n")
        try repo.commitAll("base")
        try repo.sh("git -C '\(repo.path)' checkout -q -b feat")
        try repo.write("a.txt", "one\ntwo\n")                                  // modified
        try FileManager.default.removeItem(atPath: "\(repo.path)/b.txt")       // deleted
        try repo.sh("git -C '\(repo.path)' mv c.txt d.txt")                   // renamed (staged)
        try repo.write("e.txt", "staged new\n")
        try repo.sh("git -C '\(repo.path)' add e.txt")                        // added (staged)
        try repo.write("new dir/ünï code.txt", "x\ny")                         // untracked, nested, no final newline

        let state = try git.changes(in: GitComparison(base: "main"))
        let files = byPath(state)
        XCTAssertEqual(state.files.map(\.path), ["a.txt", "b.txt", "d.txt", "e.txt", "new dir/ünï code.txt"])
        XCTAssertEqual(files["a.txt"]?.status, .modified)
        XCTAssertEqual(files["a.txt"]?.added, 1)
        XCTAssertEqual(files["a.txt"]?.removed, 0)
        XCTAssertEqual(files["b.txt"]?.status, .deleted)
        XCTAssertEqual(files["d.txt"]?.status, .renamed)
        XCTAssertEqual(files["d.txt"]?.oldPath, "c.txt")
        XCTAssertEqual(files["e.txt"]?.status, .added)
        XCTAssertEqual(files["e.txt"]?.isUntracked, false)
        let untracked = try XCTUnwrap(files["new dir/ünï code.txt"])
        XCTAssertEqual(untracked.status, .added)
        XCTAssertTrue(untracked.isUntracked)
        XCTAssertEqual(untracked.added, 2)
        XCTAssertNotNil(state.stamps["a.txt"])
        XCTAssertEqual(state.mergeBase, try GitRunner.run(in: repo.path, ["rev-parse", "main"]))
    }

    func testRefComparisonExcludesWorkingTree() throws {
        try repo.sh("git -C '\(repo.path)' checkout -q -b feat")
        try repo.write("committed.txt", "c\n")
        try repo.commitAll("c")
        try repo.write("dirty.txt", "d\n")
        let state = try git.changes(in: GitComparison(base: "main", head: .ref("feat")))
        XCTAssertEqual(state.files.map(\.path), ["committed.txt"])
        XCTAssertTrue(state.stamps.isEmpty)
    }

    func testBinaryAndModeOnlyChanges() throws {
        try Data([0, 1, 2]).write(to: URL(fileURLWithPath: "\(repo.path)/bin.dat"))
        try repo.write("run.sh", "echo hi\n")
        try repo.commitAll("base")
        try Data([0, 1, 3]).write(to: URL(fileURLWithPath: "\(repo.path)/bin.dat"))
        try repo.sh("chmod +x '\(repo.path)/run.sh'")

        let state = try git.changes(in: GitComparison(base: "main"))
        let files = byPath(state)
        XCTAssertEqual(files["bin.dat"]?.isBinary, true)
        XCTAssertNil(files["bin.dat"]?.added)
        let script = try XCTUnwrap(files["run.sh"])
        XCTAssertEqual(script.status, .modified)
        XCTAssertEqual(script.added, 0)
        XCTAssertFalse(script.isBinary)
        let diff = try git.diff(of: script, in: GitComparison(base: "main"), mergeBase: state.mergeBase)
        XCTAssertFalse(diff.isBinary)
        XCTAssertTrue(diff.hunks.isEmpty)
        XCTAssertTrue(try git.diff(of: files["bin.dat"]!, in: GitComparison(base: "main"),
                                   mergeBase: state.mergeBase).isBinary)
    }

    func testUntrackedOverSizeCapIsNotRead() throws {
        let big = "\(repo.path)/huge.log"
        FileManager.default.createFile(atPath: big, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: big))
        try handle.truncate(atOffset: UInt64(Repository.untrackedCountLimit) + 1)   // sparse, instant
        try handle.close()
        try Data("a\0b".utf8).write(to: URL(fileURLWithPath: "\(repo.path)/blob.bin"))

        let files = byPath(try git.changes(in: GitComparison(base: "main")))
        XCTAssertEqual(files["huge.log"]?.isUntracked, true)
        XCTAssertNil(files["huge.log"]?.added)
        XCTAssertEqual(files["huge.log"]?.isBinary, false)
        XCTAssertEqual(files["blob.bin"]?.isBinary, true)
    }

    /// Not in the brief: an untracked symlink's lstat size is the link text, so a size
    /// check alone lets `contents(atPath:)` follow it and read an arbitrarily large target.
    func testUntrackedSymlinkToHugeFileIsNotFollowed() throws {
        let big = "\(NSTemporaryDirectory())covey-git-target-\(UInt32.random(in: 0..<UInt32.max)).log"
        FileManager.default.createFile(atPath: big, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: big) }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: big))
        try handle.truncate(atOffset: UInt64(Repository.untrackedCountLimit) * 4)   // sparse, instant
        try handle.close()
        try FileManager.default.createSymbolicLink(atPath: "\(repo.path)/link.log", withDestinationPath: big)

        let comparison = GitComparison(base: "main")
        let state = try git.changes(in: comparison)
        let link = try XCTUnwrap(byPath(state)["link.log"])
        XCTAssertTrue(link.isUntracked)
        XCTAssertNil(link.added)
        XCTAssertFalse(link.isBinary)
        // git diffs a symlink as its target text; that read stays cheap.
        let diff = try git.diff(of: link, in: comparison, mergeBase: state.mergeBase)
        XCTAssertFalse(diff.isBinary)
        XCTAssertEqual(diff.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text), [big])
    }

    func testDiffNumbersLinesAndFullFileCarriesEveryLine() throws {
        try repo.write("f.txt", (1...30).map { "l\($0)" }.joined(separator: "\n") + "\n")
        try repo.commitAll("base")
        var lines = (1...30).map { "l\($0)" }
        lines[14] = "changed"
        try repo.write("f.txt", lines.joined(separator: "\n") + "\n")
        let comparison = GitComparison(base: "main")
        let state = try git.changes(in: comparison)
        let file = try XCTUnwrap(state.files.first)

        let diff = try git.diff(of: file, in: comparison, mergeBase: state.mergeBase)
        XCTAssertEqual(diff.hunks.count, 1)
        XCTAssertEqual(diff.hunks[0].lines.first { $0.kind == .added }?.newNumber, 15)
        XCTAssertEqual(diff.lineCount, 8)   // 3 context + 1 removed + 1 added + 3 context

        let full = try git.diff(of: file, in: comparison, mergeBase: state.mergeBase, fullFile: true)
        XCTAssertEqual(full.hunks.flatMap(\.lines).filter { $0.newNumber != nil }.count, 30)
    }

    func testDiffOfUntrackedAndRenamedFiles() throws {
        try repo.write("old.txt", (1...10).map { "r\($0)" }.joined(separator: "\n") + "\n")
        try repo.commitAll("base")
        try repo.sh("git -C '\(repo.path)' mv old.txt new.txt")
        try repo.write("new.txt", (1...10).map { "r\($0)" }.joined(separator: "\n") + "\nr11\n")
        try repo.write("fresh.txt", "a\nb\n")
        let comparison = GitComparison(base: "main")
        let state = try git.changes(in: comparison)
        let files = byPath(state)

        let renamed = try git.diff(of: files["new.txt"]!, in: comparison, mergeBase: state.mergeBase)
        XCTAssertEqual(renamed.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text), ["r11"])
        let fresh = try git.diff(of: files["fresh.txt"]!, in: comparison, mergeBase: state.mergeBase)
        XCTAssertEqual(fresh.hunks.flatMap(\.lines).map(\.kind), [.added, .added])
    }

    /// `git diff --no-index` exits 1 both for "files differ" and for real errors; only the
    /// former prints a diff. A vanished file must surface, not read as an empty diff.
    func testUntrackedDiffOfVanishedFileThrows() throws {
        try repo.write("gone.txt", "x\n")
        let comparison = GitComparison(base: "main")
        let state = try git.changes(in: comparison)
        let file = try XCTUnwrap(byPath(state)["gone.txt"])
        XCTAssertTrue(file.isUntracked)
        try FileManager.default.removeItem(atPath: "\(repo.path)/gone.txt")

        XCTAssertThrowsError(try git.diff(of: file, in: comparison, mergeBase: state.mergeBase)) { error in
            guard let kind = (error as? GitError)?.kind, case .failed = kind else {
                return XCTFail("expected GitError.failed, got \(error)")
            }
        }
    }

    func testUntrackedDiffOfSymlinkToDirectoryThrows() throws {
        let target = "\(NSTemporaryDirectory())covey-git-dirtarget-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: target) }
        try FileManager.default.createSymbolicLink(atPath: "\(repo.path)/dlnk", withDestinationPath: target)
        let comparison = GitComparison(base: "main")
        let state = try git.changes(in: comparison)
        let file = try XCTUnwrap(byPath(state)["dlnk"])
        XCTAssertTrue(file.isUntracked)

        XCTAssertThrowsError(try git.diff(of: file, in: comparison, mergeBase: state.mergeBase)) { error in
            guard let kind = (error as? GitError)?.kind, case .failed = kind else {
                return XCTFail("expected GitError.failed, got \(error)")
            }
        }
    }

    /// Guards the "exit 1 needs stdout" rule against over-tightening.
    func testUntrackedDiffOfEmptyAndBinaryFilesDoesNotThrow() throws {
        try repo.write("empty.txt", "")
        try Data("a\0b".utf8).write(to: URL(fileURLWithPath: "\(repo.path)/blob.bin"))
        let comparison = GitComparison(base: "main")
        let state = try git.changes(in: comparison)
        let files = byPath(state)

        let empty = try git.diff(of: try XCTUnwrap(files["empty.txt"]), in: comparison, mergeBase: state.mergeBase)
        XCTAssertTrue(empty.hunks.isEmpty)
        let blob = try git.diff(of: try XCTUnwrap(files["blob.bin"]), in: comparison, mergeBase: state.mergeBase)
        XCTAssertTrue(blob.isBinary)
    }

    func testDetachedHeadComparisonLoads() throws {
        try repo.write("x.txt", "x\n")
        try repo.commitAll("x")
        try repo.sh("git -C '\(repo.path)' checkout -q --detach HEAD")
        try repo.write("x.txt", "x\ny\n")
        XCTAssertNil(git.currentBranch())
        XCTAssertNotNil(git.shortHead())
        let state = try git.changes(in: GitComparison(base: "main"))
        XCTAssertEqual(state.files.map(\.path), ["x.txt"])
    }

    func testUnknownBaseThrowsUnknownRef() {
        XCTAssertThrowsError(try git.changes(in: GitComparison(base: "no-such-branch"))) { error in
            XCTAssertEqual((error as? GitError)?.kind, .unknownRef("no-such-branch"))
        }
        XCTAssertThrowsError(try git.changes(in: GitComparison(base: "--output=/tmp/x"))) { error in
            XCTAssertEqual((error as? GitError)?.kind, .unknownRef("--output=/tmp/x"))
        }
    }

    /// Not in the brief: `mergeBase` reaches git before the `--` separator, so an
    /// option-shaped value must be refused like an option-shaped ref is.
    func testDiffRefusesOptionShapedMergeBase() throws {
        try repo.write("a.txt", "one\n")
        try repo.commitAll("base")
        try repo.write("a.txt", "one\ntwo\n")
        let comparison = GitComparison(base: "main")
        let file = try XCTUnwrap(try git.changes(in: comparison).files.first)
        let sentinel = "\(NSTemporaryDirectory())covey-git-inject-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: sentinel) }

        XCTAssertThrowsError(try git.diff(of: file, in: comparison, mergeBase: "--output=\(sentinel)")) { error in
            XCTAssertEqual((error as? GitError)?.kind, .unknownRef("--output=\(sentinel)"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel))
    }

    func testFingerprintIsStableAndMovesOnEveryKindOfChange() throws {
        try repo.write("a.txt", "one\n")
        try repo.commitAll("base")
        try repo.write("a.txt", "one\ntwo\n")
        let comparison = GitComparison(base: "main")
        let paths = try git.changes(in: comparison).files.map(\.path)

        let first = try git.fingerprint(of: comparison, paths: paths)
        XCTAssertEqual(first, try git.fingerprint(of: comparison, paths: paths))

        // Same size, new content, pushed mtime: an edit to an already-changed file.
        try repo.write("a.txt", "one\nTWO\n")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: "\(repo.path)/a.txt")
        let second = try git.fingerprint(of: comparison, paths: paths)
        XCTAssertNotEqual(first, second)

        try repo.write("other.txt", "new\n")
        let third = try git.fingerprint(of: comparison, paths: paths)
        XCTAssertNotEqual(second, third)

        try repo.sh("git -C '\(repo.path)' -c user.email=t@t -c user.name=t commit -q --allow-empty -m moved")
        XCTAssertNotEqual(third, try git.fingerprint(of: comparison, paths: paths))
    }

    /// A load nothing interrupted returns the very token the next poll computes, so an idle
    /// view is not reloaded forever.
    func testQuietLoadFingerprintEqualsNextPoll() throws {
        try repo.write("a.txt", "one\n")
        try repo.write("b.txt", "bee\n")
        try repo.write("c.txt", (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n")
        try repo.commitAll("base")
        try repo.write("a.txt", "one\ntwo\n")                                    // modified
        try FileManager.default.removeItem(atPath: "\(repo.path)/b.txt")         // deleted (no stamp)
        try repo.sh("git -C '\(repo.path)' mv c.txt d.txt")                     // renamed
        try repo.write("new dir/fresh.txt", "x\n")                               // untracked
        let comparison = GitComparison(base: "main")

        let state = try git.changes(in: comparison)
        XCTAssertFalse(state.fingerprint.hasPrefix("unstable:"))
        XCTAssertEqual(state.fingerprint,
                       try git.fingerprint(of: comparison, paths: state.files.map(\.path)))
        // Ref comparisons never had a window: their token is the two commits.
        let refs = GitComparison(base: "main", head: .ref("HEAD"))
        let refState = try git.changes(in: refs)
        XCTAssertEqual(refState.fingerprint, try git.fingerprint(of: refs, paths: []))
    }

    /// An edit that lands after the path listing (same size, so status does not move; only
    /// the stamp does) must not be baked into the stored token.
    func testMidLoadEditOfTrackedFileMakesFingerprintUnstable() throws {
        try repo.write("a.txt", "one\n")
        try repo.commitAll("base")
        try repo.write("a.txt", "one\ntwo\n")
        let comparison = GitComparison(base: "main")

        let state = try git.changes(in: comparison, afterListing: {
            try? self.repo.write("a.txt", "one\nTWO\n")
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                                   ofItemAtPath: "\(self.repo.path)/a.txt")
        })
        XCTAssertTrue(state.fingerprint.hasPrefix("unstable:"))
        XCTAssertNotEqual(state.fingerprint,
                          try git.fingerprint(of: comparison, paths: state.files.map(\.path)))
        // The reload the mismatch triggers is quiet and settles.
        let reloaded = try git.changes(in: comparison)
        XCTAssertEqual(reloaded.fingerprint,
                       try git.fingerprint(of: comparison, paths: reloaded.files.map(\.path)))
    }

    func testMidLoadNewUntrackedFileMakesFingerprintUnstable() throws {
        try repo.write("a.txt", "one\n")
        try repo.commitAll("base")
        try repo.write("a.txt", "one\ntwo\n")
        let comparison = GitComparison(base: "main")

        let state = try git.changes(in: comparison, afterListing: {
            try? self.repo.write("late.txt", "arrived during the load\n")
        })
        XCTAssertEqual(state.files.map(\.path), ["a.txt"])   // not in this listing...
        XCTAssertTrue(state.fingerprint.hasPrefix("unstable:"))   // ...so the token must never match
        XCTAssertNotEqual(state.fingerprint,
                          try git.fingerprint(of: comparison, paths: state.files.map(\.path)))
        let reloaded = try git.changes(in: comparison)
        XCTAssertEqual(reloaded.files.map(\.path), ["a.txt", "late.txt"])
    }

    func testSubdirectoryRepositoryReadsTheWholeWorktree() throws {
        try repo.write("sub/tracked.txt", "one\n")
        try repo.commitAll("base")
        try repo.write("sub/tracked.txt", "one\ntwo\n")
        try repo.write("root-untracked.txt", "r\n")
        let sub = Repository(at: "\(repo.path)/sub")
        let comparison = GitComparison(base: "main")
        let state = try sub.changes(in: comparison)
        XCTAssertEqual(state.files.map(\.path), ["root-untracked.txt", "sub/tracked.txt"])
        XCTAssertEqual(state.files.first { $0.path == "root-untracked.txt" }?.added, 1)
        XCTAssertNotNil(state.stamps["sub/tracked.txt"])
        let untracked = try XCTUnwrap(state.files.first { $0.isUntracked })
        XCTAssertEqual(try sub.diff(of: untracked, in: comparison, mergeBase: state.mergeBase)
            .hunks.flatMap(\.lines).map(\.text), ["r"])
        XCTAssertEqual(try sub.fingerprint(of: comparison, paths: state.files.map(\.path)), state.fingerprint)
    }

    func testUntrackedCountingStopsAtTheFileBudget() throws {
        for name in ["a.txt", "b.txt", "c.txt"] { try repo.write(name, "x\n") }
        let state = try git.changes(in: GitComparison(base: "main"), afterListing: nil,
                                    fileBudget: 2, byteBudget: 1 << 20)
        XCTAssertEqual(state.files.map(\.added), [1, 1, nil])
        XCTAssertEqual(state.files.map(\.isUntracked), [true, true, true])
    }

    func testUntrackedCountingStopsAtTheByteBudget() throws {
        try repo.write("a.txt", String(repeating: "x\n", count: 10))   // 20 bytes
        try repo.write("b.txt", String(repeating: "y\n", count: 10))   // 20 bytes
        let state = try git.changes(in: GitComparison(base: "main"), afterListing: nil,
                                    fileBudget: 100, byteBudget: 30)
        XCTAssertEqual(state.files.map(\.added), [10, nil])
    }

    func testRefHeadPerFileDiff() throws {
        try repo.write("f.txt", "one\n")
        try repo.commitAll("base")
        try repo.sh("git -C '\(repo.path)' checkout -q -b feat")
        try repo.write("f.txt", "one\ntwo\n")
        try repo.commitAll("feat")
        try repo.write("f.txt", "one\ntwo\nuncommitted\n")
        let comparison = GitComparison(base: "main", head: .ref("feat"))
        let state = try git.changes(in: comparison)
        let file = try XCTUnwrap(state.files.first)
        let diff = try git.diff(of: file, in: comparison, mergeBase: state.mergeBase)
        XCTAssertEqual(diff.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text), ["two"])
    }

    func testNotARepositoryIsAFailureNotAnUnknownRef() throws {
        let plain = "\(NSTemporaryDirectory())covey-not-a-repo-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: plain) }
        XCTAssertThrowsError(try Repository(at: plain).changes(in: GitComparison(base: "main"))) { error in
            guard case .failed? = (error as? GitError)?.kind else {
                return XCTFail("expected .failed, got \(error)")
            }
        }
        XCTAssertNil(Repository(at: plain).resolveCommit("main"))
    }

    func testMergeBaseRefusesOptionShapedInput() {
        XCTAssertNil(git.mergeBase("--output=/tmp/x", "HEAD"))
        XCTAssertNil(git.mergeBase("HEAD", "-x"))
        XCTAssertNil(git.mergeBase("", "HEAD"))
        XCTAssertNotNil(git.mergeBase("main", "HEAD"))
    }

    func testComparisonLabelAndStorageKey() {
        XCTAssertEqual(GitComparison(base: "main").label, "main…working tree")
        XCTAssertEqual(GitComparison(base: "main", head: .ref("feat")).label, "main…feat")
        XCTAssertNotEqual(GitComparison(base: "main").storageKey,
                          GitComparison(base: "main", head: .ref("HEAD")).storageKey)
    }
}
