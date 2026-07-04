import XCTest
@testable import CoveyKit

final class ProtocolTests: XCTestCase {
    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
    
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        let data = try encoder().encode(value)
        let back = try JSONDecoder().decode(T.self, from: data)
        XCTAssertEqual(value, back)
    }
    
    func testRequestOpRoundTrip() throws {
        let ops: [Request.Op] = [
            .list,
            .create(dir: "/work", agent: "claude", argv: ["claude"], name: nil,
                    terminal: nil, worktree: nil, model: nil, effort: nil, resume: nil),
            .create(dir: "/work", agent: "claude", argv: nil, name: "s9",
                    terminal: true, worktree: .new(branch: "b", base: "main"),
                    model: "opus", effort: "max", resume: "claude --resume u"),
            .create(dir: "/work", agent: "claude", argv: nil, name: nil,
                    terminal: nil, worktree: .checkout(branch: "feat"),
                    model: nil, effort: nil, resume: nil),
            .create(dir: "/work", agent: "claude", argv: nil, name: nil,
                    terminal: nil, worktree: .checkoutNew(branch: "feat", base: "main"),
                    model: nil, effort: nil, resume: nil),
            .kill(name: "s-1", removeWorktree: nil),
            .kill(name: "s-1", removeWorktree: true),
            .restart(name: "s-1", dir: nil),
            .restart(name: "s-1", dir: "/repo"),
            .rename(name: "a", newName: "b"),
            .attach(name: "s-1", sinceSeq: 42),
            .detach(name: "s-1"),
            .input(name: "s-1", bytesB64: "aGk="),
            .resize(name: "s-1", cols: 80, rows: 24),
            .gitInfo(dir: "/work"),
            .promote(name: "s-1"),
            .deleteBranch(dir: "/work", branch: "feat"),
            .mergedBranches(dir: "/work"),
            .cleanupBranches(dir: "/work", branches: ["a", "b"]),
        ]
        for op in ops { try roundTrip(Request(id: 7, op: op)) }
    }
    
    func testServerMessageRoundTrip() throws {
        let s = Session(name: "s-1", dir: "/w", cwd: "/w", agent: "claude", created: 1)
        let msgs: [ServerMessage] = [
            .response(id: 1, result: .ok),
            .response(id: 2, result: .session(s)),
            .response(id: 3, result: .sessions(sessions: [s], statuses: ["s-1": .running], lost: [s])),
            .response(id: 4, result: .error(code: "notFound", message: "no such session")),
            .response(id: 5, result: .sessions(sessions: [s], statuses: [:], lost: nil)),
            .response(id: 6, result: .gitInfo(repoRoot: "/w", currentBranch: "main",
                                              branches: ["main", "dev"],
                                              worktrees: ["main": "/w"])),
            .response(id: 7, result: .gitInfo(repoRoot: nil, currentBranch: nil,
                                              branches: [], worktrees: nil)),
            .response(id: 9, result: .branches(["feat", "fix"])),
            .response(id: 8, result: .session(Session(name: "r", dir: "/w", cwd: "/w",
                                                      agent: "claude", created: 2,
                                                      resumeCmd: "claude --resume u"))),
            .event(.output(name: "s-1", seq: 5, bytesB64: "aGk=")),
            .event(.sessionAdded(session: s)),
            .event(.sessionRemoved(name: "s-1")),
            .event(.statusChanged(name: "s-1", status: .waiting)),
            .event(.promptChanged(name: "s-1", options: ["yes", "no"])),
            .event(.gitChanged(name: "s-1", git: GitInfo(branch: "main", added: 1, removed: 2))),
            .event(.gitChanged(name: "s-1", git: nil)),
            .event(.exited(name: "s-1", code: 0)),
        ]
        for m in msgs { try roundTrip(m) }
    }
    
    func testGoldenWireFormat() throws {
        let line = { (v: Request) in String(decoding: try self.encoder().encode(v), as: UTF8.self) }
        XCTAssertEqual(
            try line(Request(id: 1, op: .list)), #"{"id":1,"op":{"list":{}}}"#
        )
        XCTAssertEqual(
            try line(
                Request(id: 2, op: .kill(name: "s-1", removeWorktree: nil))
            ), #"{"id":2,"op":{"kill":{"name":"s-1"}}}"#
        )
        // nil optionals are omitted:
        XCTAssertEqual(
            try line(
                Request(id: 3, op: .create(dir: "/w", agent: "claude", argv: nil, name: nil,
                                           terminal: nil, worktree: nil, model: nil,
                                           effort: nil, resume: nil))
            ), #"{"id":3,"op":{"create":{"agent":"claude","dir":"/w"}}}"#
        )
    }

    func testStatusChangedGoldenWireFormat() throws {
        let data = try encoder().encode(DaemonEvent.statusChanged(name: "s-1", status: .waiting))
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"statusChanged":{"name":"s-1","status":"waiting"}}"#
        )
    }
}

