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
        server.handle(Request(id: 10, op: .create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "s1", terminal: nil, worktree: nil, model: nil, effort: nil, resume: nil)), from: sink)
        waitUntil({ sink.captured.contains { if case .response(10, .session) = $0 { return true }; return false } }, "create response")
        waitUntil({ sink.captured.contains { if case .event(.sessionAdded) = $0 { return true }; return false } }, "added event")
        server.handle(Request(id: 11, op: .kill(name: "s1", removeWorktree: nil)), from: sink)
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
        server.handle(Request(id: 1, op: .create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "s1", terminal: nil, worktree: nil, model: nil, effort: nil, resume: nil)), from: sink)
        server.handle(Request(id: 2, op: .attach(name: "s1", sinceSeq: nil)), from: sink)
        server.handle(Request(id: 3, op: .input(name: "s1", bytesB64: Data("ping\n".utf8).base64EncodedString())), from: sink)
        waitUntil({ sink.captured.contains {
            if case .event(.output(_, _, let b64)) = $0,
               let d = Data(base64Encoded: b64) { return String(decoding: d, as: UTF8.self).contains("ping") }
            return false
        } }, "live output")
        server.handle(Request(id: 4, op: .kill(name: "s1", removeWorktree: nil)), from: sink)
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
            effort: nil, resume: nil)), from: sink)
        waitUntil({ registry.snapshotScreens()["menu"]?.contains("2. no") == true },
                  "menu rendered")
        monitor.tick()
        waitUntil({ sink.captured.contains {
            if case .event(.statusChanged("menu", .waiting)) = $0 { return true }
            return false
        } }, "statusChanged waiting")
        server.handle(Request(id: 2, op: .list), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(2, .sessions(_, let statuses, _)) = $0 {
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
            if case .response(1, .sessions(_, _, let lost)) = $0 { return lost?.map(\.name) == ["old"] }
            return false
        } }, "list carries lost")
        server.handle(Request(id: 2, op: .clearLost), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(2, .ok) = $0 { return true }; return false
        } }, "clearLost acked")
        server.handle(Request(id: 3, op: .list), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(3, .sessions(_, _, let lost)) = $0 { return lost == nil }
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
            model: nil, effort: nil, resume: nil)), from: sink)
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
                                                 model: nil, effort: nil, resume: nil)), from: sink)
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
        server.handle(Request(id: 6, op: .kill(name: "plain", removeWorktree: nil)), from: sink)
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
