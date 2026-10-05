import XCTest
@testable import CoveyCodeGraph

final class ModelTests: XCTestCase {
    func testStandardLimitsMatchTheSpec() {
        XCTAssertEqual(GraphLimits.standard.budget, .seconds(5))
        XCTAssertEqual(GraphLimits.standard.maxCandidates, 2000)
        XCTAssertEqual(GraphLimits.standard.maxFileBytes, 1_048_576)
    }

    func testChangedSourceNamesBothSides() {
        let added = ChangedSource(path: "a.rs", change: .added)
        let deleted = ChangedSource(path: "b.rs", change: .deleted)
        let moved = ChangedSource(path: "new.rs", change: .renamed(from: "old.rs"))
        XCTAssertEqual([added.basePath, added.headPath], [nil, "a.rs"])
        XCTAssertEqual([deleted.basePath, deleted.headPath], ["b.rs", nil])
        XCTAssertEqual([moved.basePath, moved.headPath], ["old.rs", "new.rs"])
    }

    func testNotesAreEnglishAndCarryTheReason() {
        XCTAssertEqual(LinkGraph.incompleteNote, "links incomplete")
        let failed = LinkGraph.unavailable("git exited 128")
        XCTAssertEqual(failed.note, "links unavailable: git exited 128")
        XCTAssertTrue(failed.links.isEmpty)
        XCTAssertFalse(failed.complete)
        XCTAssertEqual(LinkGraph.empty.links, [])
        XCTAssertTrue(LinkGraph.empty.complete)
    }

    func testFakeProviderMatchesWholeWordsOnly() async throws {
        let fake = FakeProvider(head: [
            "a.rs": "use crate::client::Pay;",
            "b.rs": "let clients = 1;",
            "c.ts": "import { x } from '@acme/ui/button'",
        ])
        let hits = try await fake.filesMentioning(["client"])
        XCTAssertEqual(hits, ["a.rs"])
        let scoped = try await fake.filesMentioning(["@acme/ui"])
        XCTAssertEqual(scoped, ["c.ts"])
    }

    func testFakeProviderDiffsItsSides() {
        let fake = FakeProvider(common: ["same.py": "x"],
                                base: ["gone.py": "1", "edit.py": "a", "old.py": "o"],
                                head: ["new.py": "2", "edit.py": "b", "moved.py": "o"])
        XCTAssertEqual(fake.changes(renames: ["old.py": "moved.py"]), [
            ChangedSource(path: "edit.py", change: .modified),
            ChangedSource(path: "gone.py", change: .deleted),
            ChangedSource(path: "moved.py", change: .renamed(from: "old.py")),
            ChangedSource(path: "new.py", change: .added),
        ])
    }
}
