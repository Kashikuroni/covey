# covey Lifecycle (Slice 17) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Session restart (claude resumes, others relaunch fresh), restart-all-claude with a typed confirmation, and return-to-root for sessions whose worktree was removed.

**Architecture:** The daemon owns restarts: `SessionRegistry.restart` marks the session, kills the child with the existing SIGHUP escalation, and `handleExit` — instead of removing the entry — parses a fresh `claude --resume` hint from the dying process's scrollback tail, then respawns a new PTY into the SAME entry (screen, name, subscribers survive; the IPC layer re-binds output fanout via a new `onRestarted` callback and upserts the client with `sessionAdded`). Every claude exit (restart or not) refreshes `resumeCmd` from output — catching `/clear` — before the recents snapshot. GUI adds three chords: `space s u` (confirm-restart selected), `space a u` (typed yes/да restart-all), `space g r` (return to root). Spec: `docs/superpowers/specs/2026-07-03-covey-lifecycle-design.md`.

**Tech Stack:** Swift 6.3 / SwiftPM, XCTest. Registry tests run real PTYs (`/bin/cat`, `/bin/sh`), no network.

## Global Constraints

- All code, comments, and string literals in English (docs/ excepted).
- Git write operations are performed BY THE USER; each task ends with the exact command.
- Golden wire-format lines in ProtocolTests must stay valid: `.restart` is a new op; its `dir` is optional and omitted when nil.
- Resume-hint validation is strict (the value lands in `sh -c`): bare token must be a 36-char lowercase-hex UUID with dashes at 8/13/18/23; quoted name must be ASCII alphanumerics plus `-`/`_`/`.` only — anything else is rejected, not sanitized.
- The confirmation gate accepts exactly `yes` or `да` — trimmed, case-insensitive, complete word.
- Test runs: `swift test --filter <ClassName>`; full suite: `swift test`.
- Smoke REQUIRES a daemon restart first (`pkill -f coveyd; rm -f ~/.covey/coveyd.sock`).

---

### Task 1: resume-hint parser + scrollback tail access

**Files:**
- Create: `Sources/CoveydCore/ResumeParse.swift`
- Modify: `Sources/CoveydCore/ScrollbackBuffer.swift` (add `tail`)
- Modify: `Sources/CoveydCore/PTYProcess.swift` (add `scrollbackTail`)
- Test: `Tests/CoveydCoreTests/ResumeParseTests.swift` (new)

**Interfaces:**
- Consumes: `ScrollbackBuffer.since(_:)`, `headSeq`/`tailSeq` (existing).
- Produces (used by Task 2):

```swift
func parseResumeCommand(_ pane: String) -> String?      // internal to CoveydCore
func stripANSI(_ s: String) -> String
// ScrollbackBuffer
public func tail(_ maxBytes: Int) -> [UInt8]
// PTYProcess
public func scrollbackTail(_ maxBytes: Int) -> [UInt8]
```

- [ ] **Step 1: Failing tests** — create `Tests/CoveydCoreTests/ResumeParseTests.swift`:

```swift
import XCTest
@testable import CoveydCore

final class ResumeParseTests: XCTestCase {
    func testParsesBareUUID() {
        let pane = "some output\nTo continue: claude --resume 12345678-1234-1234-1234-123456789abc\n"
        XCTAssertEqual(parseResumeCommand(pane),
                       "claude --resume 12345678-1234-1234-1234-123456789abc")
    }

    func testParsesLastHintAndIgnoresTrailingText() {
        let pane = """
        claude --resume 11111111-1111-1111-1111-111111111111
        ^Cclaude --resume 22222222-2222-2222-2222-222222222222 (to continue)
        """
        XCTAssertEqual(parseResumeCommand(pane),
                       "claude --resume 22222222-2222-2222-2222-222222222222",
                       "scans lines from the end; text after the token ignored")
    }

    func testParsesQuotedName() {
        XCTAssertEqual(parseResumeCommand(#"claude --resume "my_session.1""#),
                       #"claude --resume "my_session.1""#)
    }

    func testRejectsShellMetacharactersInName() {
        XCTAssertNil(parseResumeCommand(#"claude --resume "a;b""#))
        XCTAssertNil(parseResumeCommand(#"claude --resume "a$b""#))
        XCTAssertNil(parseResumeCommand(#"claude --resume "a`b`""#))
        XCTAssertNil(parseResumeCommand(#"claude --resume """#))
    }

    func testRejectsMalformedUUID() {
        XCTAssertNil(parseResumeCommand("claude --resume 1234"))
        XCTAssertNil(parseResumeCommand("claude --resume 12345678-1234-1234-1234-12345678ZABC"))
        XCTAssertNil(parseResumeCommand("claude --resume 12345678x1234-1234-1234-123456789abc"))
    }

    func testStripsANSIBeforeMatching() {
        let pane = "\u{1b}[1mclaude --resume \u{1b}[0m12345678-1234-1234-1234-123456789abc"
        XCTAssertEqual(parseResumeCommand(pane),
                       "claude --resume 12345678-1234-1234-1234-123456789abc")
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(parseResumeCommand(""))
        XCTAssertNil(parseResumeCommand("   \n   "))
    }

    func testScrollbackTailReturnsLastBytes() {
        let buf = ScrollbackBuffer(limit: 100)
        _ = buf.append(Array("0123456789".utf8))
        XCTAssertEqual(buf.tail(4), Array("6789".utf8))
        XCTAssertEqual(buf.tail(100), Array("0123456789".utf8), "cap larger than content")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ResumeParseTests`
Expected: FAIL — compile errors, `parseResumeCommand`/`tail` undefined.

- [ ] **Step 3: Implement** — create `Sources/CoveydCore/ResumeParse.swift` (port of `amux-core/tmux/parse.rs` strip_ansi / parse_resume_command / validators):

```swift
/// Removes ANSI/CSI escape sequences: skip ESC and everything up to the
/// sequence's final byte (an ASCII letter). Port of parse.rs strip_ansi.
func stripANSI(_ s: String) -> String {
    var out = String()
    out.reserveCapacity(s.count)
    var it = s.makeIterator()
    while let c = it.next() {
        if c == "\u{1b}" {
            while let n = it.next(), !(n.isASCII && n.isLetter) {}
        } else {
            out.append(c)
        }
    }
    return out
}

/// Scans output for the LAST `claude --resume <id>` hint and returns it as a
/// ready-to-run string. The value lands in `sh -c`, so both token forms are
/// validated strictly — anything suspicious is rejected, never sanitized.
/// Port of parse.rs parse_resume_command.
func parseResumeCommand(_ pane: String) -> String? {
    let hint = "claude --resume "
    let clean = stripANSI(pane)
    for line in clean.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
        guard let r = line.range(of: hint, options: .backwards) else { continue }
        let rest = line[r.upperBound...]
        if rest.hasPrefix("\"") {
            let name = String(rest.dropFirst().prefix(while: { $0 != "\"" }))
            if isResumeName(name) { return "\(hint)\"\(name)\"" }
        } else if let token = rest.split(separator: " ").first.map(String.init),
                  isResumeUUID(token) {
            return hint + token
        }
    }
    return nil
}

/// Quoted session names: ASCII alphanumerics plus -/_/. only (shell-safe).
private func isResumeName(_ s: String) -> Bool {
    !s.isEmpty && s.allSatisfy {
        ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" || $0 == "."
    }
}

/// Bare tokens: exactly a 36-char lowercase-hex UUID, dashes at 8/13/18/23.
private func isResumeUUID(_ s: String) -> Bool {
    let b = Array(s.utf8)
    guard b.count == 36 else { return false }
    for (i, c) in b.enumerated() {
        if i == 8 || i == 13 || i == 18 || i == 23 {
            if c != UInt8(ascii: "-") { return false }
        } else if !((c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9"))
                    || (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "f"))) {
            return false
        }
    }
    return true
}
```

In `Sources/CoveydCore/ScrollbackBuffer.swift` add:

```swift
    /// The last `maxBytes` of retained scrollback (fewer when the buffer holds
    /// less). For scanning exit output — never blocks on the pty queue.
    public func tail(_ maxBytes: Int) -> [UInt8] {
        since(max(headSeq, tailSeq - maxBytes)).bytes
    }
```

(If `since`/`headSeq`/`tailSeq` synchronize via an internal lock, `tail` inherits that; match the file's existing locking pattern when editing.)

In `Sources/CoveydCore/PTYProcess.swift`, next to `backfill`:

```swift
    /// The last `maxBytes` of scrollback (see ScrollbackBuffer.tail). Used to
    /// scan a dying claude's output for its `--resume` hint.
    public func scrollbackTail(_ maxBytes: Int) -> [UInt8] {
        buffer.tail(maxBytes)
    }
```

- [ ] **Step 4: Green**

Run: `swift test --filter ResumeParseTests`
Expected: PASS. Also `swift test --filter ScrollbackBufferTests` still PASS.

- [ ] **Step 5: Hand the commit to the user**

```bash
git add Sources/CoveydCore/ResumeParse.swift Sources/CoveydCore/ScrollbackBuffer.swift Sources/CoveydCore/PTYProcess.swift Tests/CoveydCoreTests/ResumeParseTests.swift
git commit -m "feat(coveyd): resume-hint parser + scrollback tail access (parse.rs port)"
```

---

### Task 2: SessionRegistry.restart + resumeCmd refresh on exit

**Files:**
- Modify: `Sources/CoveydCore/SessionRegistry.swift`
- Modify: `Sources/CoveydCore/CreateService.swift` (add `resumeArgv`)
- Test: `Tests/CoveydCoreTests/SessionRegistryTests.swift`

**Interfaces:**
- Consumes: `parseResumeCommand`, `PTYProcess.scrollbackTail` (Task 1); `resumeLaunchCommand` (CoveyKit, 15.1).
- Produces (used by Task 3):

```swift
// RegistryError
case dirMissing(String)
// SessionRegistry
public var onRestarted: ((Session) -> Void)?
public func restart(name: String, dir: String? = nil) throws
// CreateService
public static func resumeArgv(_ resumeCmd: String) -> [String]
```

- [ ] **Step 1: Failing tests** — append to `Tests/CoveydCoreTests/SessionRegistryTests.swift`:

```swift
    func testRestartRespawnsSameEntry() throws {
        let reg = SessionRegistry()
        let restarted = expectation(description: "restarted")
        var updated: Session?
        reg.onRestarted = { s in updated = s; restarted.fulfill() }
        reg.onExit = { _, _ in XCTFail("restart must not emit exit") }
        reg.onSessionRemoved = { _ in XCTFail("restart must not remove") }
        _ = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "r1")
        try reg.restart(name: "r1")
        wait(for: [restarted], timeout: 5)
        XCTAssertEqual(updated?.name, "r1")
        XCTAssertEqual(updated?.dir, "/usr", "no override: same dir")
        XCTAssertEqual(reg.list().map(\.name), ["r1"], "entry survived the restart")
        reg.onExit = nil; reg.onSessionRemoved = nil
        reg.kill(name: "r1")
    }

    func testRestartDirOverride() throws {
        let reg = SessionRegistry()
        let restarted = expectation(description: "restarted")
        var updated: Session?
        reg.onRestarted = { s in updated = s; restarted.fulfill() }
        _ = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "r2")
        try reg.restart(name: "r2", dir: "/tmp")
        wait(for: [restarted], timeout: 5)
        XCTAssertEqual(updated?.dir, "/tmp", "return-to-root respawns in the override dir")
        reg.kill(name: "r2")
    }

    func testRestartMissingDirThrows() throws {
        let reg = SessionRegistry()
        _ = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "r3")
        XCTAssertThrowsError(try reg.restart(name: "r3", dir: "/definitely/not/here")) {
            XCTAssertEqual($0 as? RegistryError, .dirMissing("/definitely/not/here"))
        }
        XCTAssertThrowsError(try reg.restart(name: "ghost")) {
            XCTAssertEqual($0 as? RegistryError, .notFound("ghost"))
        }
        reg.kill(name: "r3")
    }

    func testRestartClaudeUsesResumeArgv() throws {
        // A claude session (resumeCmd set) respawns through the resume command
        // with the 15.1 fallback wrapper — visible in the persisted argv.
        // Capture the meta the moment it carries the respawn argv: the
        // respawned sh may exit (claude absent) and persist again before the
        // assertion runs.
        var claudeMeta: SessionMeta?
        let reg = SessionRegistry(onPersist: { metas in
            if let m = metas.first(where: { $0.name == "cl" }), m.argv.first == "/bin/sh" {
                claudeMeta = m
            }
        })
        let restarted = expectation(description: "restarted")
        reg.onRestarted = { _ in restarted.fulfill() }
        _ = try reg.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"],
                           name: "cl", resumeCmd: "claude --resume 12345678-1234-1234-1234-123456789abc")
        try reg.restart(name: "cl")
        wait(for: [restarted], timeout: 5)
        XCTAssertEqual(claudeMeta?.argv.first, "/bin/sh")
        XCTAssertTrue(claudeMeta?.argv.last?.contains("--resume 12345678") == true,
                      "\(claudeMeta?.argv ?? [])")
        XCTAssertTrue(claudeMeta?.argv.last?.contains("|| ") == true, "fallback wrapper present")
        reg.kill(name: "cl")
    }

    func testExitRefreshesResumeCmdFromOutput() throws {
        // claude prints its resume hint on exit; the registry re-reads it so
        // recents (and the next restart) carry the post-/clear uuid.
        let reg = SessionRegistry()
        let exited = expectation(description: "exited")
        var upserted: Session?
        reg.onSessionAdded = { s in
            if s.resumeCmd != "claude --resume old" { upserted = s }
        }
        reg.onExit = { _, _ in exited.fulfill() }
        let hint = "claude --resume 12345678-1234-1234-1234-123456789abc"
        _ = try reg.create(dir: "/tmp", agent: "claude",
                           argv: ["/bin/sh", "-c", "echo '\(hint)'"],
                           name: "cl2", resumeCmd: "claude --resume old")
        wait(for: [exited], timeout: 5)
        XCTAssertEqual(upserted?.resumeCmd, hint, "fresh hint upserted before exited")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SessionRegistryTests`
Expected: FAIL — `onRestarted`/`restart`/`dirMissing` undefined (compile errors).

- [ ] **Step 3: CreateService.resumeArgv** — in `Sources/CoveydCore/CreateService.swift`, below `prepare`:

```swift
    /// The argv a claude restart runs: the (fresh) resume command hardened by
    /// resumeLaunchCommand, first word resolved like any create.
    public static func resumeArgv(_ resumeCmd: String) -> [String] {
        ["/bin/sh", "-c", resolveCommand(resumeLaunchCommand(resumeCmd))]
    }
```

- [ ] **Step 4: Registry implementation** — in `Sources/CoveydCore/SessionRegistry.swift`:

**4a.** `RegistryError` gains a case:

```swift
public enum RegistryError: Error, Equatable {
    case duplicateName(String)
    case notFound(String)
    case dirMissing(String)
}
```

**4b.** New state next to `pendingWorktreeRemoval`, callback next to `onSessionRemoved`, and per-entry size tracking. The entry tuple grows a `size` field:

```swift
    public var onRestarted: ((Session) -> Void)?
    private var entries: [String: (session: Session, process: PTYProcess,
                                   screen: ScreenModel, argv: [String],
                                   size: (cols: UInt16, rows: UInt16))] = [:]
    private var pendingRestart: [String: String] = [:]   // name -> respawn dir
```

`create` stores `size: (80, 24)` when inserting; `resize` records the new size:

```swift
    public func resize(name: String, cols: UInt16, rows: UInt16) {
        guard let entry = withEntry(name) else { return }
        entry.process.resize(cols: cols, rows: rows)
        entry.screen.resize(cols: Int(cols), rows: Int(rows))
        lock.lock()
        entries[name]?.size = (cols, rows)
        lock.unlock()
    }
```

**4c.** `restart`:

```swift
    /// Kills the session's child and respawns it in place once it exits:
    /// claude resumes its conversation, anything else reruns its argv. `dir`
    /// overrides the respawn directory (return-to-root). The entry, screen and
    /// scrollback survive; no exited/sessionRemoved events fire.
    public func restart(name: String, dir: String? = nil) throws {
        lock.lock()
        guard let entry = entries[name] else {
            lock.unlock(); throw RegistryError.notFound(name)
        }
        let target = dir ?? entry.session.dir
        lock.unlock()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDir),
              isDir.boolValue else {
            throw RegistryError.dirMissing(target)
        }
        lock.lock()
        pendingRestart[name] = target
        lock.unlock()
        kill(name: name)
    }
```

**4d.** `handleExit` rework (replaces the whole method):

```swift
    private func handleExit(_ proc: PTYProcess, _ code: Int32) {
        lock.lock()
        guard let id = entries.first(where: { $0.value.process === proc })?.key,
              let entry = entries[id] else {
            lock.unlock()
            return
        }
        let restartDir = pendingRestart.removeValue(forKey: id)
        lock.unlock()

        // A dying claude prints its resume hint; re-read it so the stored
        // command survives /clear having rotated the conversation id.
        var freshResume: String?
        if entry.session.resumeCmd != nil {
            let tail = String(decoding: proc.scrollbackTail(4096), as: UTF8.self)
            freshResume = parseResumeCommand(tail)
        }

        if let restartDir,
           let respawned = respawn(id: id, dir: restartDir, resume: freshResume) {
            persistNow()
            onRestarted?(respawned)
            return
        }
        // No pending restart — or the respawn failed: normal exit path.

        lock.lock()
        var updated: Session?
        if let fresh = freshResume, fresh != entries[id]?.session.resumeCmd {
            entries[id]?.session.resumeCmd = fresh
            updated = entries[id]?.session
        }
        entries[id] = nil
        let removal = pendingWorktreeRemoval.removeValue(forKey: id)
        lock.unlock()
        persistNow()
        if let updated { onSessionAdded?(updated) }   // recents read the client cache
        if let removal {
            try? GitOps.removeWorktree(repo: removal.repo, wtPath: removal.path)
        }
        onExit?(id, code)
    }

    /// Respawns a pending-restart session in `dir`. Returns the updated
    /// session, or nil when the spawn failed (caller falls through to the
    /// normal exit path). Command resolution shells out — never under the lock.
    private func respawn(id: String, dir: String, resume: String?) -> Session? {
        lock.lock()
        guard let old = entries[id] else { lock.unlock(); return nil }
        lock.unlock()

        var session = old.session
        if let resume { session.resumeCmd = resume }
        let argv = session.resumeCmd.map { CreateService.resumeArgv($0) } ?? old.argv
        let proc = PTYProcess()
        proc.setExitHandler { [weak self, weak proc] code in
            guard let proc else { return }
            self?.handleExit(proc, code)
        }
        let screen = old.screen
        proc.setOutputHandler { bytes, _ in screen.feed(bytes) }
        do {
            try proc.spawn(argv: argv, cwd: dir, cols: old.size.cols, rows: old.size.rows)
        } catch {
            return nil
        }
        session.dir = dir
        session.cwd = dir
        session.git = nil        // GitMonitor re-reads for the (possibly new) dir
        lock.lock()
        entries[id] = (session, proc, screen, argv, old.size)
        lock.unlock()
        return session
    }
```

- [ ] **Step 5: Green + full suite**

Run: `swift test --filter SessionRegistryTests && swift test`
Expected: PASS everywhere (create/rename call sites updated for the grown tuple).

- [ ] **Step 6: Hand the commit to the user**

```bash
git add Sources/CoveydCore/SessionRegistry.swift Sources/CoveydCore/CreateService.swift Tests/CoveydCoreTests/SessionRegistryTests.swift
git commit -m "feat(coveyd): in-place session restart + resumeCmd refresh on exit"
```

---

### Task 3: protocol op `.restart` — server, client, AppModel

**Files:**
- Modify: `Sources/CoveyKit/Protocol.swift:21` (Op)
- Modify: `Sources/CoveyKit/IPCClient.swift` (restart)
- Modify: `Sources/CoveydCore/IPCServer.swift` (dispatch + onRestarted wiring + errorResult)
- Modify: `Sources/covey/AppModel.swift` (restart, restartAllClaude)
- Test: `Tests/CoveyKitTests/ProtocolTests.swift`
- Test: `Tests/CoveydCoreTests/IPCServerTests.swift`

**Interfaces:**
- Consumes: `SessionRegistry.restart`, `onRestarted`, `RegistryError.dirMissing` (Task 2).
- Produces (used by Task 4):

```swift
// Request.Op
case restart(name: String, dir: String?)
// IPCClient
public func restart(name: String, dir: String? = nil) async throws
// AppModel
@discardableResult public func restart(_ name: String, dir: String? = nil) async -> String?
public func restartAllClaude() async -> [String]
```

- [ ] **Step 1: Failing protocol test** — in `Tests/CoveyKitTests/ProtocolTests.swift`, `testRequestOpRoundTrip`, add to `ops` after `.kill(name: "s-1", removeWorktree: true),`:

```swift
            .restart(name: "s-1", dir: nil),
            .restart(name: "s-1", dir: "/repo"),
```

Run: `swift test --filter ProtocolTests`
Expected: FAIL — `.restart` undefined.

- [ ] **Step 2: Protocol + client** —

`Sources/CoveyKit/Protocol.swift`, in `Request.Op` after `case kill(...)`:

```swift
        // Kill the child and respawn it in place; `dir` overrides the respawn
        // directory (return-to-root). claude resumes, other agents rerun argv.
        case restart(name: String, dir: String?)
```

`Sources/CoveyKit/IPCClient.swift`, next to `kill`:

```swift
    public func restart(name: String, dir: String? = nil) async throws {
        try await expectOK(.restart(name: name, dir: dir))
    }
```

Run: `swift test --filter ProtocolTests`
Expected: PASS.

- [ ] **Step 3: Failing server test** — append to `Tests/CoveydCoreTests/IPCServerTests.swift`:

```swift
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
```

Run: `swift test --filter IPCServerTests.testRestartRespawnsAndUpserts`
Expected: FAIL — dispatch has no `.restart` case (switch not exhaustive).

- [ ] **Step 4: Server + AppModel** —

`Sources/CoveydCore/IPCServer.swift`, in `init` after the `registry.onSessionRemoved` block:

```swift
        registry.onRestarted = { [weak self] s in
            guard let self else { return }
            // The respawn created a new PTYProcess — re-bind the output fanout
            // to it; subscribers are keyed by name and survive untouched.
            self.attachOutputFanout(for: s.name)
            self.broadcast(.event(.sessionAdded(session: s)))   // client upserts
        }
```

In `dispatch`, after the `.kill` case:

```swift
        case let .restart(name, dir):
            guard registry.get(name: name) != nil else { return notFound(name) }
            do { try registry.restart(name: name, dir: dir); reply(.ok) }
            catch let e as RegistryError { reply(errorResult(e)) }
            catch { reply(.error(code: "restartFailed", message: "\(error)")) }
```

In `errorResult`, add:

```swift
        case .dirMissing(let d):
            return .error(code: "restartFailed", message: "directory missing: \(d)")
```

`Sources/covey/AppModel.swift`, next to `kill`:

```swift
    /// Restart via the daemon; the error text doubles as the sheet's inline
    /// banner. `dir` overrides the respawn directory (return-to-root).
    @discardableResult
    public func restart(_ name: String, dir: String? = nil) async -> String? {
        do { try await client.restart(name: name, dir: dir); return nil }
        catch { let msg = errorText(error); toast = msg; return msg }
    }

    /// The `space a u` bulk restart: every session whose agent's first word is
    /// claude. Returns per-session error lines (empty = all good).
    public func restartAllClaude() async -> [String] {
        var errors: [String] = []
        for s in sessions where s.agent.split(separator: " ").first == "claude" {
            if let err = await restart(s.name) { errors.append("\(s.name): \(err)") }
        }
        return errors
    }
```

- [ ] **Step 5: Green + full suite**

Run: `swift test --filter IPCServerTests && swift test`
Expected: PASS.

- [ ] **Step 6: Hand the commit to the user**

```bash
git add Sources/CoveyKit/Protocol.swift Sources/CoveyKit/IPCClient.swift Sources/CoveydCore/IPCServer.swift Sources/covey/AppModel.swift Tests/CoveyKitTests/ProtocolTests.swift Tests/CoveydCoreTests/IPCServerTests.swift
git commit -m "feat(coveyd): restart protocol op — respawn in place, fanout re-bind"
```

---

### Task 4: GUI — chords, sheets, returnable badge

**Files:**
- Create: `Sources/covey/Lifecycle.swift`
- Modify: `Sources/covey/KeyRouter.swift` (KeyAction + 3 chords)
- Modify: `Sources/covey/AppModel.swift` (Modal cases + apply cases)
- Modify: `Sources/covey/Views/Sheets.swift` (Modal.id + RestartSheet + RestartAllSheet)
- Modify: `Sources/covey/Views/ContentView.swift` (modal host cases)
- Modify: `Sources/covey/Views/SessionListView.swift` (returnable badge)
- Modify: `Sources/covey/Views/WhichKeyView.swift`, `Sources/covey/Views/HelpOverlay.swift`
- Test: `Tests/CoveyAppTests/LifecycleTests.swift` (new)
- Test: `Tests/CoveyAppTests/KeyRouterTests.swift`

**Interfaces:**
- Consumes: `model.restart`, `model.restartAllClaude` (Task 3); `Session.worktreeRepo/git/agent`.
- Produces:

```swift
func confirmsRestart(_ buffer: String) -> Bool
func isReturnable(_ s: Session, dirExists: (String) -> Bool = ...) -> Bool
func shellSingleQuote(_ s: String) -> String
// KeyAction
case restartSelected, restartAllPrompt, returnToRoot
// AppModel.Modal
case restart(String), restartAll
```

- [ ] **Step 1: Failing pure tests** — create `Tests/CoveyAppTests/LifecycleTests.swift`:

```swift
import XCTest
@testable import covey
import CoveyKit

final class LifecycleTests: XCTestCase {
    func testConfirmsRestart() {
        XCTAssertTrue(confirmsRestart("yes"))
        XCTAssertTrue(confirmsRestart("  YES "))
        XCTAssertTrue(confirmsRestart("да"))
        XCTAssertTrue(confirmsRestart("Да"))
        XCTAssertFalse(confirmsRestart("y"))
        XCTAssertFalse(confirmsRestart("yes!"))
        XCTAssertFalse(confirmsRestart(""))
        XCTAssertFalse(confirmsRestart("no"))
    }

    func testIsReturnable() {
        let wt = Session(name: "w", dir: "/r/.worktrees/f", cwd: "/r/.worktrees/f",
                         agent: "claude", created: 1, worktreeRepo: "/r")
        XCTAssertTrue(isReturnable(wt, dirExists: { _ in false }), "worktree dir gone")
        XCTAssertFalse(isReturnable(wt, dirExists: { _ in true }), "worktree alive")
        let plain = Session(name: "p", dir: "/gone", cwd: "/gone", agent: "sh", created: 1)
        XCTAssertFalse(isReturnable(plain, dirExists: { _ in false }),
                       "non-worktree session has no root to return to")
    }

    func testShellSingleQuote() {
        XCTAssertEqual(shellSingleQuote("/a b"), "'/a b'")
        XCTAssertEqual(shellSingleQuote("a'b"), "'a'\\''b'")
    }
}
```

Run: `swift test --filter LifecycleTests`
Expected: FAIL — functions undefined.

- [ ] **Step 2: Implement Lifecycle.swift** — create `Sources/covey/Lifecycle.swift`:

```swift
import Foundation
import CoveyKit

/// Lifecycle helpers (port of app.rs confirms_restart / the Returnable card
/// state / tmux.rs shell_single_quote).

/// The restart-all gate accepts exactly "yes" — or "да", so the confirm works
/// without leaving a Russian layout. Trimmed, case-insensitive, complete word.
func confirmsRestart(_ buffer: String) -> Bool {
    let t = buffer.trimmingCharacters(in: .whitespaces).lowercased()
    return t == "yes" || t == "да"
}

/// A worktree session whose directory vanished from disk — the worktree was
/// removed under it (promote from another session, cleanup, by hand). Checked
/// on disk, not via git==nil: a freshly created session has no git info yet.
func isReturnable(_ s: Session,
                  dirExists: (String) -> Bool = {
                      var isDir: ObjCBool = false
                      return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir)
                          && isDir.boolValue
                  }) -> Bool {
    s.worktreeRepo != nil && !dirExists(s.dir)
}

/// POSIX single-quoting: the only special character inside '' is ' itself.
func shellSingleQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
```

Run: `swift test --filter LifecycleTests`
Expected: PASS.

- [ ] **Step 3: Failing chord tests** — in `Tests/CoveyAppTests/KeyRouterTests.swift`, append to the leader-menu test (the one asserting `.promoteSelected` etc.):

```swift
        XCTAssertEqual(KeyRouter.route(key("u"), context: ctx(mode: .leader(.session))),
                       .restartSelected)
        XCTAssertEqual(KeyRouter.route(key("u"), context: ctx(mode: .leader(.app))),
                       .restartAllPrompt)
        XCTAssertEqual(KeyRouter.route(key("r"), context: ctx(mode: .leader(.git))),
                       .returnToRoot)
```

Run: `swift test --filter KeyRouterTests`
Expected: FAIL — cases undefined.

- [ ] **Step 4: Router + model + sheets** —

`Sources/covey/KeyRouter.swift` — `KeyAction` gains, after `case cleanupBranches`:

```swift
    case restartSelected
    case restartAllPrompt
    case returnToRoot
```

`routeLeader` gains, next to the existing `.git`/`.session` cases:

```swift
        case (.session, "u"): return .restartSelected
        case (.app, "u"): return .restartAllPrompt
        case (.git, "r"): return .returnToRoot
```

`Sources/covey/AppModel.swift` — `Modal` gains:

```swift
        case restart(String)
        case restartAll
```

`apply` gains, next to `.promoteSelected`:

```swift
        case .restartSelected:
            inputMode = .normal
            if let selected { modal = .restart(selected) }
        case .restartAllPrompt:
            inputMode = .normal
            modal = .restartAll
        case .returnToRoot:
            inputMode = .normal
            guard let s = selectedSession() else { return }
            guard isReturnable(s), let root = s.worktreeRepo else {
                toast = "worktree still alive"; return
            }
            if s.agent.split(separator: " ").first == "claude" {
                // Same pipeline as a plain restart, but respawned in the root.
                Task { await restart(s.name, dir: root) }
            } else {
                // A live shell just cd's back (port of the TUI behavior).
                let cmd = "cd \(shellSingleQuote(root))\n"
                Task { try? await client.input(name: s.name, bytes: Array(cmd.utf8)) }
            }
```

`Sources/covey/Views/Sheets.swift` — `Modal.id` gains:

```swift
        case .restart(let name): return "restart-\(name)"
        case .restartAll: return "restart-all"
```

and two sheets after `KillSheet`:

```swift
struct RestartSheet: View {
    let model: AppModel
    let name: String
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restart \"\(name)\"?").font(.headline)
            Text("claude resumes the conversation; other agents relaunch fresh.")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Text("! \(error)").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Restart") {
                    Task {
                        if let err = await model.restart(name) { error = err }
                        else { model.modal = nil }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

struct RestartAllSheet: View {
    let model: AppModel
    @State private var confirmation = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restart all claude sessions?").font(.headline)
            Text("Each claude session exits and resumes its conversation. Type yes to confirm.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("yes", text: $confirmation)
                .onSubmit { if confirmsRestart(confirmation) { run() } }
            if let error {
                Text("! \(error)").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Restart all") { run() }
                    .disabled(!confirmsRestart(confirmation))
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func run() {
        Task {
            let errors = await model.restartAllClaude()
            if errors.isEmpty { model.modal = nil }
            else { error = errors.joined(separator: " · ") }
        }
    }
}
```

`Sources/covey/Views/ContentView.swift` — modal host gains, next to the `.kill` case:

```swift
            case .restart(let name): RestartSheet(model: model, name: name)
            case .restartAll: RestartAllSheet(model: model)
```

`Sources/covey/Views/SessionListView.swift` — in `row(_:)`, replace the git line block's opening so a returnable session shows the badge instead:

```swift
            if isReturnable(session) {
                Text("⧉ worktree removed — space g r returns to root")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if let git = session.git {
```

(the existing `if let git = session.git { … }` body stays as the `else if` body).

`Sources/covey/Views/WhichKeyView.swift` — update rows:
- `.session` menu: add `Row(key: "u", label: "restart session", implemented: true)`.
- `.app` menu: the existing `Row(key: "u", label: "restart all claude sessions (later)", implemented: false)` becomes `Row(key: "u", label: "restart all claude sessions", implemented: true)`.
- `.git` menu: add `Row(key: "r", label: "return to repo root", implemented: true)`.
- root `.git` summary row label: `"git — issue · promote · delete branch · cleanup · return"`;
  root `.session` summary row label: `"session — rename · restart · verify · nvim"`.

`Sources/covey/Views/HelpOverlay.swift` — extend the leader-chord lines: the `("g", …)` entry text gains `· return to root`, and add/extend entries so `s u` («restart session») and `a u` («restart all claude») are listed; match the file's existing tuple format.

- [ ] **Step 5: Green + full suite**

Run: `swift test --filter "KeyRouterTests|LifecycleTests" && swift test`
Expected: PASS.

- [ ] **Step 6: Smoke** — restart the daemon and run the app:

```bash
pkill -f coveyd; rm -f ~/.covey/coveyd.sock
swift run covey
```

1. Live claude session → `space s u` → Restart → terminal keeps history, claude comes back resumed (same conversation). Switch to another session and back — the terminal re-renders from the fresh backfill (post-restart output only; the daemon-side scrollback restarts with the new process).
2. `space a u` → sheet demands typed `yes`/`да`; garbage keeps the button disabled; confirm → every claude session restarts; non-claude (shell) sessions untouched.
3. Worktree session A + root session B; kill A with «remove worktree» while a THIRD session C also sits in that worktree — C's card shows `⧉ worktree removed`; `space g r` on C → claude returns resumed in the repo root (shell: gets `cd <root>`).
4. `/clear` inside a claude session, then `space s u` → restart resumes the POST-clear conversation.
5. Recent: kill a claude session after `/clear` → Relaunch resumes the post-clear conversation (fresh uuid in recents).

- [ ] **Step 7: Hand the commit to the user**

```bash
git add Sources/covey/Lifecycle.swift Sources/covey/KeyRouter.swift Sources/covey/AppModel.swift Sources/covey/Views/Sheets.swift Sources/covey/Views/ContentView.swift Sources/covey/Views/SessionListView.swift Sources/covey/Views/WhichKeyView.swift Sources/covey/Views/HelpOverlay.swift Tests/CoveyAppTests/LifecycleTests.swift Tests/CoveyAppTests/KeyRouterTests.swift
git commit -m "feat(covey): restart/restart-all/return-to-root chords, sheets and card badge"
```
