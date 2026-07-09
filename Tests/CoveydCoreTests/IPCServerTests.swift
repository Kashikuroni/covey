import XCTest
@testable import CoveydCore
import CoveyKit

final class FakeSink: ClientSink {
    let id: Int
    private let lock = NSLock()
    private var messages: [ServerMessage] = []
    init(id: Int) { self.id = id }
    func send(_ message: ServerMessage) { lock.lock(); messages.append(message); lock.unlock() }
    var captured: [ServerMessage] { lock.lock(); defer { lock.unlock() }; return messages }
}

final class IPCServerTests: XCTestCase {
    func testCreateReturnsSessionAndBroadcastsAdded() {
        let registry = SessionRegistry(clock: { 1 })
        let server = IPCServer(registry: registry,
                               monitor: StatusMonitor(snapshot: { registry.snapshotScreens() }))
        let sink = FakeSink(id: 1)
        server.register(sink)
        server.handle(Request(id: 10, op: .create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "s1", terminal: nil, worktree: nil, model: nil, effort: nil, resume: nil, companionOf: nil)), from: sink)
        waitUntil({ sink.captured.contains { if case .response(10, .session) = $0 { return true }; return false } }, "create response")
        waitUntil({ sink.captured.contains { if case .event(.sessionAdded) = $0 { return true }; return false } }, "added event")
        server.handle(Request(id: 11, op: .kill(name: "s1", removeWorktree: nil)), from: sink)
    }

    func testCreateCompanionDerivesNameAndKillCascades() {
        let registry = SessionRegistry(clock: { 1 })
        let server = IPCServer(registry: registry,
                               monitor: StatusMonitor(snapshot: { registry.snapshotScreens() }))
        let sink = FakeSink(id: 1)
        server.register(sink)
        server.handle(Request(id: 1, op: .create(dir: "/tmp", agent: "claude",
                                                 argv: ["/bin/cat"], name: "agent",
                                                 terminal: nil, worktree: nil, model: nil,
                                                 effort: nil, resume: nil, companionOf: nil)),
                      from: sink)
        server.handle(Request(id: 2, op: .create(dir: "/tmp", agent: "zsh",
                                                 argv: ["/bin/cat"], name: "ignored",
                                                 terminal: nil, worktree: nil, model: nil,
                                                 effort: nil, resume: nil, companionOf: "agent")),
                      from: sink)
        // The daemon derives the companion name, ignoring the client's.
        waitUntil({ sink.captured.contains {
            if case .response(2, .session(let s)) = $0 {
                return s.name == "agent+sh" && s.companionOf == "agent"
            }
            return false
        } }, "companion session derived name")
        server.handle(Request(id: 3, op: .kill(name: "agent", removeWorktree: nil)), from: sink)
        waitUntil({ sink.captured.contains {
            if case .event(.exited(name: "agent+sh", _)) = $0 { return true }; return false
        } }, "companion cascades on kill")
    }

    func testModelMonitorEventAndListPayload() throws {
        let root = "\(NSTemporaryDirectory())covey-ipc-models-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: "\(root)/-usr",
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let uuid = "0b154175-0f2e-43e8-b5b0-97ec3cb0e6a4"
        try #"{"type":"assistant","message":{"model":"claude-fable-5"}}"#
            .write(toFile: "\(root)/-usr/\(uuid).jsonl", atomically: true, encoding: .utf8)

        let registry = SessionRegistry(clock: { 1 })
        let modelMonitor = ModelMonitor(projectsRoot: root, snapshot: {
            registry.list().map { ($0.name, $0.cwd, $0.resumeCmd) }
        })
        let server = IPCServer(registry: registry,
                               monitor: StatusMonitor(snapshot: { registry.snapshotScreens() }),
                               modelMonitor: modelMonitor)
        let sink = FakeSink(id: 1)
        server.register(sink)
        _ = try registry.create(dir: "/usr", agent: "claude", argv: ["/bin/cat"],
                                name: "s1", resumeCmd: "claude --resume \(uuid)")
        modelMonitor.tick()
        waitUntil({ sink.captured.contains {
            if case .event(.modelChanged(name: "s1", model: "claude-fable-5")) = $0 { return true }
            return false
        } }, "modelChanged event")
        server.handle(Request(id: 7, op: .list), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(7, .sessions(_, _, _, let models)) = $0 {
                return models?["s1"] == "claude-fable-5"
            }
            return false
        } }, "models in list payload")
        registry.kill(name: "s1")
    }

    func testUnknownNameReturnsNotFound() {
        let registry = SessionRegistry()
        let server = IPCServer(registry: registry,
                               monitor: StatusMonitor(snapshot: { registry.snapshotScreens() }))
        let sink = FakeSink(id: 1)
        server.register(sink)
        server.handle(Request(id: 5, op: .kill(name: "ghost", removeWorktree: nil)), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(5, .error(let code, _)) = $0 { return code == "notFound" }; return false
        } }, "notFound error")
    }

    func testAttachStreamsBackfillAndLiveOutput() {
        let registry = SessionRegistry()
        let server = IPCServer(registry: registry,
                               monitor: StatusMonitor(snapshot: { registry.snapshotScreens() }))
        let sink = FakeSink(id: 1)
        server.register(sink)
        server.handle(Request(id: 1, op: .create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "s1", terminal: nil, worktree: nil, model: nil, effort: nil, resume: nil, companionOf: nil)), from: sink)
        server.handle(Request(id: 2, op: .attach(name: "s1", sinceSeq: nil)), from: sink)
        server.handle(Request(id: 3, op: .input(name: "s1", bytesB64: Data("ping\n".utf8).base64EncodedString())), from: sink)
        waitUntil({ sink.captured.contains {
            if case .event(.output(_, _, let b64)) = $0,
               let d = Data(base64Encoded: b64) { return String(decoding: d, as: UTF8.self).contains("ping") }
            return false
        } }, "live output")
        server.handle(Request(id: 4, op: .kill(name: "s1", removeWorktree: nil)), from: sink)
    }

    func testAttachPrefixesStatePreambleToBackfill() {
        let registry = SessionRegistry()
        let server = IPCServer(registry: registry,
                               monitor: StatusMonitor(snapshot: { registry.snapshotScreens() }))
        let sink = FakeSink(id: 1)
        server.register(sink)
        // The stream flips alt screen + mouse on; in real sessions those
        // one-shot DECSETs age out of the 1 MB ring, so the preamble must
        // come from parsed state, not from the backfill still holding them.
        server.handle(Request(id: 1, op: .create(
            dir: "/usr", agent: "sh",
            argv: ["/bin/sh", "-c", "printf '\\033[?1049h\\033[?1002h\\033[?1006hFRAME'; exec cat"],
            name: "tui", terminal: nil, worktree: nil, model: nil,
            effort: nil, resume: nil, companionOf: nil)), from: sink)
        waitUntil({ registry.statePreamble(name: "tui")?.isEmpty == false },
                  "modes parsed before attach")
        server.handle(Request(id: 2, op: .attach(name: "tui", sinceSeq: nil)), from: sink)
        // Strict check: the backfill itself STARTS with the same DECSETs the
        // preamble synthesizes, so the payload must contain them twice —
        // synthesized preamble first, untouched backfill right after. A
        // plain hasPrefix(preamble) would pass even without the fix.
        let preamble = "\u{1b}[?1049h\u{1b}[?1002h\u{1b}[?1006h"
        waitUntil({ sink.captured.contains {
            if case .event(.output("tui", _, let b64)) = $0,
               let d = Data(base64Encoded: b64) {
                return String(decoding: d, as: UTF8.self)
                    .hasPrefix(preamble + preamble + "FRAME")
            }
            return false
        } }, "first output = preamble + backfill")
        server.handle(Request(id: 3, op: .kill(name: "tui", removeWorktree: nil)), from: sink)
    }

    func testTickBroadcastsWaitingAndListCarriesStatuses() {
        let registry = SessionRegistry()
        let monitor = StatusMonitor(snapshot: { registry.snapshotScreens() })
        let server = IPCServer(registry: registry, monitor: monitor)
        let sink = FakeSink(id: 1)
        server.register(sink)
        // A session whose screen ends in a numbered menu -> waiting.
        server.handle(Request(id: 1, op: .create(
            dir: "/tmp", agent: "sh",
            argv: ["/bin/sh", "-c", "printf 'pick:\\n  1. yes\\n  2. no\\n'; exec cat"],
            name: "menu", terminal: nil, worktree: nil, model: nil,
            effort: nil, resume: nil, companionOf: nil)), from: sink)
        waitUntil({ registry.snapshotScreens()["menu"]?.contains("2. no") == true },
                  "menu rendered")
        monitor.tick()
        waitUntil({ sink.captured.contains {
            if case .event(.statusChanged("menu", .waiting)) = $0 { return true }
            return false
        } }, "statusChanged waiting")
        server.handle(Request(id: 2, op: .list), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(2, .sessions(_, let statuses, _, _)) = $0 {
                return statuses["menu"] == .waiting
            }
            return false
        } }, "list has statuses")
        server.handle(Request(id: 3, op: .kill(name: "menu", removeWorktree: nil)), from: sink)
    }

    func testListCarriesLostAndClearLostRemoves() {
        let meta = SessionMeta(name: "old", dir: "/tmp", agent: "claude",
                               argv: ["claude"], created: 1)
        let registry = SessionRegistry(persisted: [meta])
        let server = IPCServer(registry: registry,
                               monitor: StatusMonitor(snapshot: { registry.snapshotScreens() }))
        let sink = FakeSink(id: 1)
        server.register(sink)
        server.handle(Request(id: 1, op: .list), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(1, .sessions(_, _, let lost, _)) = $0 { return lost?.map(\.name) == ["old"] }
            return false
        } }, "list carries lost")
        server.handle(Request(id: 2, op: .clearLost), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(2, .ok) = $0 { return true }; return false
        } }, "clearLost acked")
        server.handle(Request(id: 3, op: .list), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(3, .sessions(_, _, let lost, _)) = $0 { return lost == nil }
            return false
        } }, "lost cleared")
    }

    func testCreateWithWorktreeAndKillRemoveWorktree() throws {
        let repo = "\(NSTemporaryDirectory())covey-ipcgit-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        for cmd in ["git -C '\(repo)' init -q -b main",
                    "git -C '\(repo)' -c user.email=t@t -c user.name=t commit --allow-empty -q -m init"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            try p.run(); p.waitUntilExit()
        }
        let registry = SessionRegistry()
        let server = IPCServer(registry: registry,
                               monitor: StatusMonitor(snapshot: { registry.snapshotScreens() }))
        let sink = FakeSink(id: 1)
        server.register(sink)
        server.handle(Request(id: 1, op: .create(
            dir: repo, agent: "sh", argv: nil, name: "wt",
            terminal: nil, worktree: .new(branch: "wt-branch", base: "main"),
            model: nil, effort: nil, resume: nil, companionOf: nil)), from: sink)
        var created: Session?
        waitUntil({ sink.captured.contains {
            if case .response(1, .session(let s)) = $0 { created = s; return true }
            return false
        } }, "worktree create response")
        XCTAssertTrue(created?.dir.hasSuffix(".worktrees/wt-branch") == true)
        XCTAssertNotNil(created?.worktreeRepo)
        let wtPath = created!.dir
        server.handle(Request(id: 2, op: .kill(name: "wt", removeWorktree: true)), from: sink)
        waitUntil({ !FileManager.default.fileExists(atPath: wtPath) },
                  "worktree removed after exit")
    }

    func testPromoteGuardsAndCleanupFlow() throws {
        let repo = "\(NSTemporaryDirectory())covey-ipcact-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        for cmd in ["git -C '\(repo)' init -q -b main",
                    "git -C '\(repo)' -c user.email=t@t -c user.name=t commit --allow-empty -q -m init",
                    "git -C '\(repo)' branch merged-b"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            try p.run(); p.waitUntilExit()
        }
        let registry = SessionRegistry()
        let server = IPCServer(registry: registry,
                               monitor: StatusMonitor(snapshot: { registry.snapshotScreens() }))
        let sink = FakeSink(id: 1)
        server.register(sink)
        // promote a plain (non-worktree) session -> promoteFailed
        server.handle(Request(id: 1, op: .create(dir: repo, agent: "sh", argv: ["/bin/cat"],
                                                 name: "plain", terminal: nil, worktree: nil,
                                                 model: nil, effort: nil, resume: nil, companionOf: nil)), from: sink)
        server.handle(Request(id: 2, op: .promote(name: "plain")), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(2, .error(let code, _)) = $0 { return code == "promoteFailed" }
            return false
        } }, "promote refuses non-worktree")
        // deleteBranch protected -> error
        server.handle(Request(id: 3, op: .deleteBranch(dir: repo, branch: "main")), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(3, .error(let code, _)) = $0 { return code == "deleteBranchFailed" }
            return false
        } }, "protected branch refused")
        // mergedBranches lists merged-b; cleanup deletes it, protected untouched
        server.handle(Request(id: 4, op: .mergedBranches(dir: repo)), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(4, .branches(let list)) = $0 { return list.contains("merged-b") }
            return false
        } }, "merged list")
        server.handle(Request(id: 5, op: .cleanupBranches(dir: repo,
                                                          branches: ["merged-b", "main"])), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(5, .ok) = $0 { return true }; return false
        } }, "cleanup ok")
        XCTAssertFalse(GitOps.branchExists(repo, "merged-b"))
        XCTAssertTrue(GitOps.branchExists(repo, "main"), "protected skipped, not failed")
        // promote with a companion: the shell dies, then the tree promotes.
        let wt = "\(repo)/.worktrees/feat"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "git -C '\(repo)' worktree add -q -b feat '\(wt)'"]
        try p.run(); p.waitUntilExit()
        _ = try registry.create(dir: wt, agent: "sh", argv: ["/bin/cat"],
                                name: "wts", worktreeRepo: repo)
        _ = try registry.create(dir: wt, agent: "zsh", argv: ["/bin/cat"],
                                name: "wts+sh", companionOf: "wts")
        server.handle(Request(id: 7, op: .promote(name: "wts")), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(7, .ok) = $0 { return true }; return false
        } }, "promote ok with companion")
        waitUntil({ sink.captured.contains {
            if case .event(.exited(name: "wts+sh", _)) = $0 { return true }; return false
        } }, "companion killed by promote")
        server.handle(Request(id: 6, op: .kill(name: "plain", removeWorktree: nil)), from: sink)
        server.handle(Request(id: 8, op: .kill(name: "wts", removeWorktree: nil)), from: sink)
    }

    func testRestartRespawnsAndUpserts() throws {
        let registry = SessionRegistry()
        let server = IPCServer(registry: registry,
                               monitor: StatusMonitor(snapshot: { registry.snapshotScreens() }))
        let sink = FakeSink(id: 1)
        server.register(sink)
        _ = try registry.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "r1")
        server.handle(Request(id: 1, op: .restart(name: "r1", dir: "/tmp")), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(1, .ok) = $0 { return true }; return false
        } }, "restart ok")
        waitUntil({ sink.captured.contains {
            if case .event(.sessionAdded(let s)) = $0 { return s.name == "r1" && s.dir == "/tmp" }
            return false
        } }, "upsert with the new dir")
        XCTAssertFalse(sink.captured.contains {
            if case .event(.exited(let n, _)) = $0 { return n == "r1" }
            return false
        }, "no exited during a restart")
        server.handle(Request(id: 2, op: .restart(name: "r1", dir: "/definitely/not/here")),
                      from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(2, .error(let code, _)) = $0 { return code == "restartFailed" }
            return false
        } }, "missing dir surfaces restartFailed")
        registry.kill(name: "r1")
    }

    func testGitInfoRepoAndNonRepo() throws {
        let repo = "\(NSTemporaryDirectory())covey-ipcinfo-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        for cmd in ["git -C '\(repo)' init -q -b main",
                    "git -C '\(repo)' -c user.email=t@t -c user.name=t commit --allow-empty -q -m init"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            try p.run(); p.waitUntilExit()
        }
        let registry = SessionRegistry()
        let server = IPCServer(registry: registry,
                               monitor: StatusMonitor(snapshot: { registry.snapshotScreens() }))
        let sink = FakeSink(id: 1)
        server.register(sink)
        server.handle(Request(id: 1, op: .gitInfo(dir: repo)), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(1, .gitInfo(let root, let cur, let branches, let wts)) = $0 {
                return root != nil && cur == "main" && branches == ["main"]
                    && wts?.keys.contains("main") == true
            }
            return false
        } }, "gitInfo for a repo")
        server.handle(Request(id: 2, op: .gitInfo(dir: NSTemporaryDirectory())), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(2, .gitInfo(let root, let cur, let branches, let wts)) = $0 {
                return root == nil && cur == nil && branches.isEmpty && (wts ?? [:]).isEmpty
            }
            return false
        } }, "gitInfo for a non-repo")
    }
}
