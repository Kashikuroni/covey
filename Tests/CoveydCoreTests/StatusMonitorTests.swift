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
