import XCTest
import CoveyGit
import CoveyCodeGraph
@testable import covey

/// A throwaway repository on `main` with one empty commit (CoveyGitTests'
/// `TestRepo` lives in another test target).
private final class ScratchRepo {
    let path: String

    init() throws {
        path = "\(NSTemporaryDirectory())covey-graph-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try sh("git -C '\(path)' init -q -b main")
        try commitAll("init", allowEmpty: true)
    }

    func remove() { try? FileManager.default.removeItem(atPath: path) }

    func sh(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitError("sh failed: \(command)") }
    }

    func git(_ args: String) throws { try sh("git -C '\(path)' \(args)") }

    func write(_ rel: String, _ content: String) throws {
        try writeData(rel, Data(content.utf8))
    }

    func writeData(_ rel: String, _ data: Data) throws {
        let full = (path as NSString).appendingPathComponent(rel)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: full))
    }

    func commitAll(_ message: String, allowEmpty: Bool = false) throws {
        try git("add -A")
        try git("-c user.email=t@t -c user.name=t commit -q \(allowEmpty ? "--allow-empty" : "") -m '\(message)'")
    }

    func head() throws -> String {
        try XCTUnwrap(Repository(at: path).resolveCommit("HEAD"))
    }
}

final class GitSourceProviderTests: XCTestCase {
    private var repo: ScratchRepo!

    override func setUpWithError() throws { repo = try ScratchRepo() }
    override func tearDown() { repo.remove() }

    func testChangedFilesMapToChangedSources() {
        let files = [
            ChangedFile(path: "a.py", status: .added, added: 1, removed: 0, isUntracked: true),
            ChangedFile(path: "b.py", status: .modified, added: 1, removed: 1),
            ChangedFile(path: "c.py", status: .deleted, added: 0, removed: 3),
            ChangedFile(path: "new/d.py", oldPath: "old/d.py", status: .renamed, added: 0, removed: 0),
            ChangedFile(path: "e.py", status: .renamed, added: 1, removed: 0),
        ]
        XCTAssertEqual(ReviewGraphInput.changes(files), [
            ChangedSource(path: "a.py", change: .added),
            ChangedSource(path: "b.py", change: .modified),
            ChangedSource(path: "c.py", change: .deleted),
            ChangedSource(path: "new/d.py", change: .renamed(from: "old/d.py")),
            ChangedSource(path: "e.py", change: .added),
        ])
    }

    func testGoneAtHeadKeepsAPathTheChangeFilledAgain() {
        let changes = [
            ChangedSource(path: "gone.py", change: .deleted),
            ChangedSource(path: "b.py", change: .renamed(from: "a.py")),
            ChangedSource(path: "c.py", change: .renamed(from: "old.py")),
            ChangedSource(path: "old.py", change: .added),
        ]
        XCTAssertEqual(ReviewGraphInput.goneAtHead(changes), ["gone.py", "a.py"])
    }

    func testDecodeRejectsBinaryNonUTF8AndOversizedData() {
        XCTAssertEqual(GitSourceProvider.decode(Data("héllo\r\n".utf8), maxBytes: 64), "héllo\r\n")
        XCTAssertNil(GitSourceProvider.decode(Data([0x61, 0x00, 0x62]), maxBytes: 64), "binary")
        XCTAssertNil(GitSourceProvider.decode(Data([0x63, 0x61, 0x66, 0xE9]), maxBytes: 64), "latin-1")
        XCTAssertNil(GitSourceProvider.decode(Data(repeating: 0x61, count: 65), maxBytes: 64), "too big")
    }

    func testWorkingTreeHeadReadsTheDiskAndLeavesGonePathsOut() async throws {
        try repo.write(".gitignore", "*.log\n")
        try repo.write("app.py", "base\n")
        try repo.write("gone.py", "old\n")
        try repo.commitAll("base")
        let base = try repo.head()
        try repo.write("app.py", "head\n")
        try repo.write("new.py", "fresh\n")
        try repo.write("noise.log", "ignored\n")
        try repo.writeData("latin1.py", Data([0x63, 0x61, 0x66, 0xE9]))
        try repo.write("big.py", String(repeating: "x", count: 100))
        try FileManager.default.removeItem(atPath: "\(repo.path)/gone.py")
        try FileManager.default.createSymbolicLink(atPath: "\(repo.path)/link.py", withDestinationPath: "app.py")
        var provider = GitSourceProvider(root: repo.path, base: base, head: .workingTree, goneAtHead: ["gone.py"])
        provider.maxBytes = 64

        let headFiles = try await provider.files(.head)
        XCTAssertEqual(headFiles, [".gitignore", "app.py", "big.py", "latin1.py", "link.py", "new.py"])
        let baseFiles = try await provider.files(.base)
        XCTAssertEqual(baseFiles, [".gitignore", "app.py", "gone.py"])
        let headApp = try await provider.text("app.py", .head)
        XCTAssertEqual(headApp, "head\n")
        let baseApp = try await provider.text("app.py", .base)
        XCTAssertEqual(baseApp, "base\n")
        let baseGone = try await provider.text("gone.py", .base)
        XCTAssertEqual(baseGone, "old\n")
        for path in ["gone.py", "latin1.py", "big.py", "link.py", "missing.py"] {
            let text = try await provider.text(path, .head)
            XCTAssertNil(text, path)
        }
        let missingAtBase = try await provider.text("new.py", .base)
        XCTAssertNil(missingAtBase)
    }

    func testCommitHeadReadsTheCommitNotTheDisk() async throws {
        try repo.write("lib.py", "def retry(): pass\n")
        try repo.commitAll("base")
        let base = try repo.head()
        try repo.git("checkout -q -b feat")
        try repo.write("user.py", "from lib import retry\n")
        try repo.commitAll("feat")
        let head = try repo.head()
        try repo.write("user.py", "edited on disk, not committed\n")
        try repo.write("scratch.py", "retry\n")
        let provider = GitSourceProvider(root: repo.path, base: base, head: .commit(head), goneAtHead: [])

        let files = try await provider.files(.head)
        XCTAssertEqual(files, ["lib.py", "user.py"])
        let text = try await provider.text("user.py", .head)
        XCTAssertEqual(text, "from lib import retry\n")
        let mentioning = try await provider.filesMentioning(["retry"])
        XCTAssertEqual(mentioning, ["lib.py", "user.py"], "untracked files are not in the commit")
    }

    func testWorkingTreeSearchFindsUntrackedFiles() async throws {
        try repo.write("lib.py", "def retry(): pass\n")
        try repo.commitAll("base")
        let base = try repo.head()
        try repo.write("scratch.py", "retry()\n")
        let provider = GitSourceProvider(root: repo.path, base: base, head: .workingTree, goneAtHead: [])
        let mentioning = try await provider.filesMentioning(["retry", "unused_word"])
        XCTAssertEqual(mentioning, ["lib.py", "scratch.py"])
    }

    func testServiceBuildsLinksOfARealComparisonIncludingBrokenOnes() async throws {
        try repo.write("pkg/__init__.py", "")
        try repo.write("pkg/util.py", "def helper():\n    return 1\n")
        try repo.write("app.py", "from pkg.util import helper\n\nprint(helper())\n")
        try repo.commitAll("base")
        try repo.git("checkout -q -b feat")
        try repo.git("mv pkg/util.py pkg/tools.py")
        try repo.write("pkg/new.py", "from pkg.tools import helper\nhelper()\n")
        let comparison = GitComparison(base: "main")
        let state = try await ReviewGitService().changes(worktree: repo.path, comparison: comparison)
        XCTAssertEqual(state.files.map(\.path), ["pkg/new.py", "pkg/tools.py"])

        let graph = await ReviewGraphService().build(worktree: repo.path, comparison: comparison, state: state)
        XCTAssertTrue(graph.complete, graph.note ?? "")
        XCTAssertEqual(graph.links, [
            Link(from: "app.py", to: "pkg/tools.py", names: ["helper"], state: .broken),
            Link(from: "pkg/new.py", to: "pkg/tools.py", names: ["helper"], state: .added),
        ])
        XCTAssertEqual(graph.usages[LinkKey(from: "app.py", to: "pkg/tools.py")]?.map(\.line), [1, 3])
    }

    func testServiceReadsARefComparisonAndReportsAnUnknownRef() async throws {
        try repo.write("lib.py", "def retry(): pass\n")
        try repo.commitAll("base")
        try repo.git("checkout -q -b feat")
        try repo.write("user.py", "from lib import retry\nretry()\n")
        try repo.commitAll("feat")
        try repo.git("checkout -q main")
        let comparison = GitComparison(base: "main", head: .ref("feat"))
        let state = try await ReviewGitService().changes(worktree: repo.path, comparison: comparison)
        let service = ReviewGraphService()

        let graph = await service.build(worktree: repo.path, comparison: comparison, state: state)
        XCTAssertEqual(graph.links, [Link(from: "user.py", to: "lib.py", names: ["retry"], state: .added)])
        let text = await service.headText(worktree: repo.path, comparison: comparison, path: "user.py")
        XCTAssertEqual(text, "from lib import retry\nretry()\n", "read from the ref, not the checked-out main")

        let gone = GitComparison(base: "main", head: .ref("nope"))
        let unavailable = await service.build(worktree: repo.path, comparison: gone, state: state)
        XCTAssertEqual(unavailable, .unavailable("unknown revision 'nope'"))
        XCTAssertEqual(unavailable.note, "links unavailable: unknown revision 'nope'")
    }
}
