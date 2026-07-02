import XCTest
@testable import CoveydCore

final class PTYProcessTests: XCTestCase {
    private func expectOutput(_ p: PTYProcess, contains needle: String) -> XCTestExpectation {
        let exp = expectation(description: "output contains \(needle)")
        exp.assertForOverFulfill = false
        var collected = [UInt8]()
        p.setOutputHandler { chunk, _ in
            collected += chunk
            if String(
                decoding: collected,
                as: UTF8.self).contains(needle) {
                    exp.fulfill()
                }
        }
        return exp
    }
    
    func testEchoProducesOutputThenExitsZero() throws {
        let p = PTYProcess()
        let outExp = expectOutput(p, contains: "hello")
        let exitExp = expectation(description: "exit")
        var code: Int32 = -999
        p.setExitHandler { code = $0; exitExp.fulfill()}
        try p.spawn(argv: ["/bin/echo", "hello"], cols: 80, rows: 24)
        wait(for: [outExp, exitExp], timeout: 5)
        XCTAssertEqual(code, 0)
    }
    
    func testCatEchoesInputThenKill() throws {
        let p = PTYProcess()
        let echoExp = expectOutput(p, contains: "ping")
        let exitExp = expectation(description: "exit")
        p.setExitHandler { _ in exitExp.fulfill()}
        try p.spawn(argv: ["/bin/cat"], cols: 80, rows: 24)
        p.write(bytes("ping\n"))
        wait(for: [echoExp], timeout: 5)
        p.kill()
        wait(for: [exitExp], timeout: 5)
    }
    
    func testNonexistentBinaryExits127() throws {
        let p = PTYProcess()
        let exitExp = expectation(description: "exit")
        var code: Int32 = -1
        p.setExitHandler { code = $0; exitExp.fulfill()}
        try p.spawn(argv: ["/nonexistent/binary"], cols: 80, rows: 24)
        wait(for: [exitExp], timeout: 5)
        XCTAssertEqual(code, 127)
    }
    
    func testInitialWinsize() throws {
        let p = PTYProcess()
        let exp = expectOutput(p, contains: "24 80")
        try p.spawn(argv: ["/bin/sh", "-c", "stty size"], cols: 80, rows: 24)
        wait(for: [exp], timeout: 5)
    }
    func testResizeUpdatesWinsize() throws {
        let p = PTYProcess()
        let exp = expectOutput(p, contains: "40 100")
        try p.spawn(argv: ["/bin/sh"], cols: 80, rows: 24)
        p.resize(cols: 100, rows: 40)
        p.write(bytes("stty size\n"))
        wait(for: [exp], timeout: 5)
        p.kill()
    }
    
    func testCwdIsRespected() throws {
        let p = PTYProcess()
        let exp = expectOutput(p, contains: "/usr")
        try p.spawn(
            argv: ["/bin/sh", "-c", "pwd"],
            cwd: "/usr",
            cols: 80,
            rows: 24
        )
        wait(for: [exp], timeout: 5)
    }

    func testMasterEOFImpliesChildExited() throws {
        // macOS pty semantics (verified empirically): the master EOFs when the
        // session leader exits (tty revoke), never while it lives — even with
        // every slave fd closed. reap()'s blocking waitpid is therefore safe:
        // by the time EOF triggers it, the child is a zombie. Pin both sides.
        let p = PTYProcess()
        let exitExp = expectation(description: "exit reported")
        p.setExitHandler { _ in exitExp.fulfill() }
        // The child detaches from the tty but keeps running: no EOF, no reap,
        // and the queue must stay responsive (backfill is queue.sync).
        try p.spawn(argv: ["/bin/sh", "-c", "exec >/dev/null 2>&1 </dev/null; sleep 30"],
                    cols: 80, rows: 24)
        var polls = 0
        waitUntil({ _ = p.backfill(since: 0); polls += 1; return polls >= 10 },
                  "queue responsive while the detached child lives")
        p.kill()   // SIGHUP the group; leader death revokes the tty -> EOF -> reap
        wait(for: [exitExp], timeout: 5)
    }

}
