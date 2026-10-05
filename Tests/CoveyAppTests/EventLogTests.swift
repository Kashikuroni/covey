import Foundation
import CoveyGit
import XCTest
@testable import covey

final class EventLogTests: XCTestCase {
    private var dir: String!
    private var captured: [(String, String)]!
    private var previousEmit: ((String, String) -> Void)!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "covey-events-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        captured = []
        previousEmit = EventLog.emit
        EventLog.emit = { [weak self] kind, message in
            self?.captured.append((kind, message))
        }
    }

    override func tearDownWithError() throws {
        EventLog.emit = previousEmit
        EventLog.directory = LogPaths.directory
        EventLog.closeForTesting()
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Captured events compared without tuple-Equatable (tuples can't).
    private func assertLogged(_ expected: [(String, String)], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(captured.count, expected.count, file: file, line: line)
        for (index, want) in expected.enumerated() where index < captured.count {
            XCTAssertEqual(captured[index].0, want.0, "event \(index) kind", file: file, line: line)
            XCTAssertEqual(captured[index].1, want.1, "event \(index) message", file: file, line: line)
        }
    }

    // MARK: The real writer (emit restored)

    private func writtenLines() throws -> [(t: Double, kind: String, msg: String)] {
        let data = try Data(contentsOf: URL(fileURLWithPath: dir + "/events.log"))
        return data.split(separator: UInt8(ascii: "\n")).map { line in
            let object = try! JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
            return (t: object["t"] as! Double, kind: object["kind"] as! String, msg: object["msg"] as! String)
        }
    }

    func testAWriteLandsOneTimestampedJSONLine() throws {
        EventLog.emit = previousEmit
        EventLog.directory = dir
        let before = Date().timeIntervalSince1970
        EventLog.note("error", "daemon went away")
        EventLog.closeForTesting()
        let after = Date().timeIntervalSince1970

        let lines = try writtenLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].kind, "error")
        XCTAssertEqual(lines[0].msg, "daemon went away")
        XCTAssertGreaterThanOrEqual(lines[0].t, before * 1000 - 1)
        XCTAssertLessThanOrEqual(lines[0].t, after * 1000 + 1)
    }

    func testASecondWriteAppends() throws {
        EventLog.emit = previousEmit
        EventLog.directory = dir
        EventLog.note("toast", "first")
        EventLog.note("error", "second")
        EventLog.closeForTesting()

        let lines = try writtenLines()
        XCTAssertEqual(lines.map(\.msg), ["first", "second"])
    }

    func testQuotesBackslashesAndNewlinesStayOnOneJSONLine() throws {
        EventLog.emit = previousEmit
        EventLog.directory = dir
        EventLog.note("error", "say \"hi\" \\ done\ntab\there")
        EventLog.closeForTesting()

        let lines = try writtenLines()
        XCTAssertEqual(lines.count, 1, "a control character must not split the line")
        XCTAssertEqual(lines[0].msg, "say ·hi· · done·tab·here")
    }

    func testAnOversizedLogIsTrimmedToItsTail() throws {
        EventLog.emit = previousEmit
        EventLog.directory = dir
        let one = Data("{\"t\":1,\"kind\":\"old\",\"msg\":\"x\"}\n".utf8)
        var old = Data()
        for _ in 0..<40_000 { old.append(one) }   // ≈ 1.36 MB of old events
        try old.write(to: URL(fileURLWithPath: dir + "/events.log"))

        EventLog.note("error", "the fresh one")
        EventLog.closeForTesting()

        let size = try FileManager.default.attributesOfItem(
            atPath: dir + "/events.log")[.size] as! Int
        XCTAssertLessThan(size, 1_000_000, "the log must be cut back under the cap")
        let lines = try writtenLines()
        XCTAssertEqual(lines.last?.msg, "the fresh one", "the newest event survives the trim")
        XCTAssertGreaterThan(lines.count, 1, "the tail keeps older lines too")
    }

    // MARK: Wiring (emit captured)

    @MainActor
    func testAppModelShowToastLogsAnEvent() throws {
        let (model, _) = try makeModel(TestDaemon())
        captured = []
        model.showToast("daemon went away")
        assertLogged([("toast", "daemon went away")])
    }

    @MainActor
    func testAReviewToastLogsAnEvent() async throws {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        captured = []

        model.toast("Sent to api")
        assertLogged([("toast", "Sent to api")])
    }

    @MainActor
    func testAReviewBannerLogsAnErrorEvent() async throws {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        captured = []

        git.fingerprintValue = "fp-moved"
        git.changesError = GitError(kind: .failed(status: 128), description: "fatal: index locked")
        await model.checkFreshness()
        XCTAssertEqual(model.banner, "fatal: index locked", "precondition: the banner is up")
        assertLogged([("error", "fatal: index locked")])
    }
}
