import XCTest
@testable import CoveydCore
import CoveyKit

final class StatusMonitorTests: XCTestCase {
    // Events are appended from the monitor queue while the test thread is
    // blocked in the synchronous tick(), so plain array access is safe.
    private func makeMonitor(_ screens: @escaping () -> [String: String])
        -> (StatusMonitor, () -> [(String, Status)]) {
        let monitor = StatusMonitor(snapshot: screens)
        let lock = NSLock()
        var events: [(String, Status)] = []
        monitor.onStatusChanged = { name, st in
            lock.lock(); events.append((name, st)); lock.unlock()
        }
        return (monitor, { lock.lock(); defer { lock.unlock() }; return events })
    }

    func testFirstTickEmitsInitialStatusThenStaysQuiet() {
        var screens = ["s": "hello"]
        let (m, events) = makeMonitor { screens }
        m.tick()
        XCTAssertEqual(events().map(\.1), [.idle])   // first observation
        m.tick()                                      // unchanged content
        XCTAssertEqual(events().count, 1)             // no spam
        screens["s"] = "hello world"
        m.tick()
        XCTAssertEqual(events().last?.1, .running)    // frame changed
    }

    func testPromptYieldsWaiting() {
        let screens = ["s": "pick one:\n  1. yes\n  2. no"]
        let (m, events) = makeMonitor { screens }
        m.tick()
        XCTAssertEqual(events().last?.1, .waiting)
        XCTAssertEqual(m.currentStatuses(), ["s": .waiting])
    }

    func testPromptOptionsEmitOnChangeOnly() {
        var screens = ["s": "pick one:\n  1. yes\n  2. no"]
        let monitor = StatusMonitor(snapshot: { screens })
        let lock = NSLock()
        var events: [(String, [String])] = []
        monitor.onPromptChanged = { name, options in
            lock.lock(); events.append((name, options)); lock.unlock()
        }
        func captured() -> [(String, [String])] {
            lock.lock(); defer { lock.unlock() }; return events
        }
        monitor.tick()
        XCTAssertEqual(captured().last?.1, ["yes", "no"])
        monitor.tick()
        XCTAssertEqual(captured().count, 1, "unchanged prompt does not re-emit")
        screens["s"] = "done, moving on"
        monitor.tick()
        XCTAssertEqual(captured().last?.1, [], "prompt gone emits empty")
        screens = [:]
        monitor.tick()
        XCTAssertEqual(captured().count, 2, "already-empty prompt set stays quiet on prune")
    }

    func testPrunedSessionWithPromptEmitsEmpty() {
        var screens = ["s": "pick one:\n  1. yes\n  2. no"]
        let monitor = StatusMonitor(snapshot: { screens })
        let lock = NSLock()
        var events: [(String, [String])] = []
        monitor.onPromptChanged = { name, options in
            lock.lock(); events.append((name, options)); lock.unlock()
        }
        monitor.tick()
        screens = [:]
        monitor.tick()
        lock.lock(); let last = events.last; lock.unlock()
        XCTAssertEqual(last?.1, [], "killed session clears its prompt")
    }

    func testWorkingMarkerYieldsRunningEvenOnFirstTick() {
        let screens = ["s": "Thinking… esc to interrupt"]
        let (m, events) = makeMonitor { screens }
        m.tick()
        XCTAssertEqual(events().last?.1, .running)
    }

    func testRemovedSessionIsPruned() {
        var screens = ["s": "hello"]
        let (m, _) = makeMonitor { screens }
        m.tick()
        XCTAssertEqual(m.currentStatuses(), ["s": .idle])
        screens = [:]
        m.tick()
        XCTAssertEqual(m.currentStatuses(), [:])
    }

    func testTimerTicksWithoutManualTick() {
        let screens = ["s": "pick:\n  1. a\n  2. b"]
        let m = StatusMonitor(interval: 0.05, snapshot: { screens })
        let exp = expectation(description: "timer tick emits waiting")
        m.onStatusChanged = { _, st in if st == .waiting { exp.fulfill() } }
        m.start()
        wait(for: [exp], timeout: 5)
        m.stop()
    }
}
