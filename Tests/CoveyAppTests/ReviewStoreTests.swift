import XCTest
import CoveyGit
@testable import covey

final class ReviewStoreTests: XCTestCase {
    private var root: String!
    private let worktree = "/tmp/covey-review-wt"
    private let comparison = GitComparison(base: "main")

    override func setUp() {
        root = "\(NSTemporaryDirectory())covey-reviews-\(UInt32.random(in: 0..<UInt32.max))"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func sampleRecord() -> ReviewRecord {
        var record = ReviewRecord(worktree: worktree, comparison: comparison)
        record.files["a.swift"] = FileReview(state: .reviewed, reviewedDiffHash: "abc")
        let anchor = LineAnchor(path: "a.swift", side: .new, line: 3, lineText: "let x = 1")
        record.comments = [ReviewComment(id: UUID(), anchor: anchor, text: "why?", createdAt: Date())]
        record.issues = [ReviewIssue(id: 1, anchor: anchor, title: "bug", body: "bug", severity: .high,
                                     status: .open, createdAt: Date())]
        record.nextIssueId = 2
        record.targetSession = "agent"
        return record
    }

    func testRoundTripThroughDisk() {
        let store = ReviewStore(root: root, debounce: 0)
        let record = sampleRecord()
        store.save(record)
        store.flush()
        let reloaded = ReviewStore(root: root, debounce: 0).load(worktree: worktree, comparison: comparison)
        XCTAssertEqual(reloaded.record, record)
        XCTAssertFalse(reloaded.recovered)
    }

    func testMissingFileGivesAnEmptyRecord() {
        let loaded = ReviewStore(root: root).load(worktree: worktree, comparison: comparison)
        XCTAssertEqual(loaded.record, ReviewRecord(worktree: worktree, comparison: comparison))
        XCTAssertFalse(loaded.recovered)
    }

    func testSavesCoalesceIntoOneWrite() {
        let store = ReviewStore(root: root, debounce: 0.2)
        var record = sampleRecord()
        for n in 2...4 {
            record.nextIssueId = n
            store.save(record)
        }
        store.flush()
        XCTAssertEqual(store.writeCount, 1)
        XCTAssertEqual(ReviewStore(root: root).load(worktree: worktree, comparison: comparison).record.nextIssueId, 4)
    }

    func testLoadSeesAPendingSave() {
        let store = ReviewStore(root: root, debounce: 10)
        let record = sampleRecord()
        store.save(record)
        XCTAssertEqual(store.load(worktree: worktree, comparison: comparison).record, record)
    }

    func testCorruptFileIsSetAsideAndReviewStartsFresh() throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let id = ReviewStore.recordID(worktree: worktree, comparison: comparison)
        let store = ReviewStore(root: root)
        try "{ not json".write(toFile: store.recordPath(id: id), atomically: true, encoding: .utf8)

        let loaded = store.load(worktree: worktree, comparison: comparison)
        XCTAssertTrue(loaded.recovered)
        XCTAssertEqual(loaded.record, ReviewRecord(worktree: worktree, comparison: comparison))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.recordPath(id: id)))
        let names = try FileManager.default.contentsOfDirectory(atPath: root)
        XCTAssertTrue(names.contains { $0.hasPrefix("\(id).corrupt-") })
    }

    func testRecordIDIsStablePerComparisonAndFollowsSymlinks() throws {
        let real = "\(root!)/real"
        let link = "\(root!)/link"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let id = ReviewStore.recordID(worktree: real, comparison: comparison)
        XCTAssertEqual(id, ReviewStore.recordID(worktree: real, comparison: comparison))
        XCTAssertEqual(id, ReviewStore.recordID(worktree: link, comparison: comparison))
        XCTAssertNotEqual(id, ReviewStore.recordID(worktree: real, comparison: GitComparison(base: "dev")))
        XCTAssertEqual(id.count, 16)
    }

    func testLastComparisonIndex() {
        let store = ReviewStore(root: root)
        XCTAssertNil(store.lastComparison(worktree: worktree))
        let ref = GitComparison(base: "main", head: .ref("feat"))
        store.setLastComparison(ref, worktree: worktree)
        XCTAssertEqual(ReviewStore(root: root).lastComparison(worktree: worktree), ref)
        XCTAssertNil(store.lastComparison(worktree: "/somewhere/else"))
    }

    func testIssueTitleIsFirstLineCappedAtSixty() {
        XCTAssertEqual(IssueTitle.make(from: "\n  Retry duplicated  \nmore"), "Retry duplicated")
        let long = String(repeating: "x", count: 80)
        let title = IssueTitle.make(from: long)
        XCTAssertEqual(title.count, 60)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertEqual(IssueTitle.make(from: "Short title\r\nbody line"), "Short title")
        XCTAssertEqual(IssueTitle.make(from: "A\rB"), "A")
    }

    func testDebouncedSaveWritesWithoutFlush() {
        let store = ReviewStore(root: root, debounce: 0.05)
        let record = sampleRecord()
        store.save(record)

        // Poll until write completes (up to ~2 seconds, 20ms intervals)
        let maxWait = 2.0
        let pollInterval = 0.02
        let deadline = Date().addingTimeInterval(maxWait)
        while store.writeCount == 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
        }

        XCTAssertEqual(store.writeCount, 1)

        // Verify a fresh store can load the written record
        let loaded = ReviewStore(root: root).load(worktree: worktree, comparison: comparison)
        XCTAssertEqual(loaded.record, record)
    }
}
