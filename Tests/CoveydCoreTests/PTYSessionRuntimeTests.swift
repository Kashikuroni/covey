import XCTest
@testable import CoveydCore

final class PTYSessionRuntimeTests: XCTestCase {
    func testEchoProducesOutputThenExitsZero() throws {
        let p = PTYSessionRuntime()
        let outExp = expectOutput(p, contains: "hello")
        let exitExp = expectation(description: "exit")
        var code: Int32 = -999
        p.setExitHandler { code = $0; exitExp.fulfill()}
        try p.spawn(argv: ["/bin/echo", "hello"], cols: 80, rows: 24)
        wait(for: [outExp, exitExp], timeout: 5)
        XCTAssertEqual(code, 0)
    }
    
    func testCatEchoesInputThenKill() throws {
        let p = PTYSessionRuntime()
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
        let p = PTYSessionRuntime()
        let exitExp = expectation(description: "exit")
        var code: Int32 = -1
        p.setExitHandler { code = $0; exitExp.fulfill()}
        try p.spawn(argv: ["/nonexistent/binary"], cols: 80, rows: 24)
        wait(for: [exitExp], timeout: 5)
        XCTAssertEqual(code, 127)
    }
    
    func testInitialWinsize() throws {
        let p = PTYSessionRuntime()
        let exp = expectOutput(p, contains: "24 80")
        try p.spawn(argv: ["/bin/sh", "-c", "stty size"], cols: 80, rows: 24)
        wait(for: [exp], timeout: 5)
    }
    func testResizeUpdatesWinsize() throws {
        let p = PTYSessionRuntime()
        let exp = expectOutput(p, contains: "40 100")
        try p.spawn(argv: ["/bin/sh"], cols: 80, rows: 24)
        p.resize(cols: 100, rows: 40)
        p.write(bytes("stty size\n"))
        wait(for: [exp], timeout: 5)
        p.kill()
    }
    
    func testKickDeliversSigwinch() throws {
        let p = PTYSessionRuntime()
        let ready = expectOutput(p, contains: "READY")
        try p.spawn(argv: ["/bin/sh", "-c",
                           "trap 'echo WINCHED' WINCH; echo READY; while :; do sleep 0.2; done"],
                    cols: 80, rows: 24)
        wait(for: [ready], timeout: 5)
        let winched = expectOutput(p, contains: "WINCHED")
        p.kick()
        wait(for: [winched], timeout: 5)
        p.kill()
    }

    func testCwdIsRespected() throws {
        let p = PTYSessionRuntime()
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
        let p = PTYSessionRuntime()
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

    func testWriteToStuckChildDoesNotWedgeQueue() throws {
        // A raw-mode child that never reads its tty (like a wedged TUI) fills
        // the kernel input queue; write() must park the excess instead of
        // blocking the pty queue — a blocked queue freezes backfill (and used
        // to freeze the whole daemon through IPCServer's queue.sync backfill,
        // and even kill()). Canonical mode discards overflow, so force raw.
        let p = PTYSessionRuntime()
        let readyExp = expectOutput(p, contains: "READY")
        let exitExp = expectation(description: "exit reported")
        p.setExitHandler { _ in exitExp.fulfill() }
        try p.spawn(argv: ["/bin/sh", "-c", "stty raw -echo; printf READY; exec sleep 30"],
                    cols: 80, rows: 24)
        wait(for: [readyExp], timeout: 5)   // raw mode is in effect from here
        p.write([UInt8](repeating: UInt8(ascii: "x"), count: 256 * 1024))
        var polls = 0
        waitUntil({ _ = p.backfill(since: 0); polls += 1; return polls >= 10 },
                  "queue responsive while input backlog is parked")
        p.kill()
        wait(for: [exitExp], timeout: 5)
    }

}
