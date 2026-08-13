import XCTest
@testable import covey
import CoveyKit
import CoveydCore

final class AppModelTests: XCTestCase {
    func testResolveProviderLaunchForClaudeGlm() {
        ProviderKeychain.write(account: "covey.provider.glm", value: "TESTKEY")
        defer { ProviderKeychain.delete(account: "covey.provider.glm") }

        let (launch, error) = AppModel.resolveProviderLaunch(
            agent: "claude", selectedProviderId: "glm"
        )

        XCTAssertNil(error)
        XCTAssertEqual(launch?.providerId, "glm")
        XCTAssertEqual(launch?.env?["ANTHROPIC_AUTH_TOKEN"], "TESTKEY")
    }

    func testResolveProviderLaunchDefaultsClaudeToAnthropic() {
        let (launch, error) = AppModel.resolveProviderLaunch(
            agent: "claude", selectedProviderId: nil
        )
        XCTAssertNil(error)
        XCTAssertEqual(launch, ProviderLaunch(env: nil, providerId: nil))
    }

    func testResolveProviderLaunchNeverInjectsIntoNonClaude() {
        let (launch, error) = AppModel.resolveProviderLaunch(
            agent: "codex", selectedProviderId: "glm"
        )
        XCTAssertNil(error)
        XCTAssertEqual(launch, ProviderLaunch(env: nil, providerId: nil))
    }

    func testResolveProviderLaunchRejectsUnknownClaudeProvider() {
        let (launch, error) = AppModel.resolveProviderLaunch(
            agent: "claude", selectedProviderId: "missing"
        )
        XCTAssertNil(launch)
        XCTAssertEqual(error, "Unknown Claude Code provider: missing")
    }

    func testResolveProviderEnvGlmWithKey() {
        ProviderKeychain.write(account: "covey.provider.glm", value: "TESTKEY")
        defer { ProviderKeychain.delete(account: "covey.provider.glm") }
        let (env, err) = AppModel.resolveProviderEnv("glm")
        XCTAssertNil(err)
        XCTAssertEqual(env?["ANTHROPIC_BASE_URL"], "https://api.z.ai/api/anthropic")
        XCTAssertEqual(env?["ANTHROPIC_AUTH_TOKEN"], "TESTKEY")
    }

    func testResolveProviderEnvGlmWithoutKey() {
        ProviderKeychain.delete(account: "covey.provider.glm")   // ensure absent
        let (env, err) = AppModel.resolveProviderEnv("glm")
        XCTAssertNil(env)
        XCTAssertNotNil(err)
    }

    func testResolveProviderEnvAnthropicIsNil() {
        let (env, err) = AppModel.resolveProviderEnv("anthropic")
        XCTAssertNil(env)
        XCTAssertNil(err)
    }

    func testDetectsSettingsJsonAnthropicConflict() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://api.z.ai/api/anthropic","other":"x"}}"#.utf8)
            .write(to: tmp)
        let conflicts = AppModel.anthropicManagedKeys(inSettingsAt: tmp.path)
        XCTAssertEqual(conflicts, ["ANTHROPIC_BASE_URL"])
    }

    func testNoConflictWhenEnvAbsentOrFileMissing() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data(#"{"theme":"dark"}"#.utf8).write(to: tmp)
        XCTAssertTrue(AppModel.anthropicManagedKeys(inSettingsAt: tmp.path).isEmpty)
        XCTAssertTrue(AppModel.anthropicManagedKeys(inSettingsAt: "/nonexistent/settings.json").isEmpty)
    }

    @MainActor
    func testStartListsExistingSessionsAndConnects() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/usr", agent: "sh",
                                       argv: ["/bin/cat"], name: "pre")
        let (model, _) = try makeModel(daemon)
        await model.start()
        XCTAssertTrue(model.connected)
        XCTAssertEqual(model.sessions.map(\.name), ["pre"])
        daemon.registry.kill(name: "pre")
    }

    @MainActor
    func testCreateAddsSessionViaEvent() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/usr", agent: "/bin/cat")
        let appeared = await eventually { model.sessions.count == 1 }
        XCTAssertTrue(appeared, "sessionAdded event did not land in model")
        await model.kill(model.sessions[0].name)
    }

    @MainActor
    func testStatusChangedUpdatesMap() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(
            dir: "/tmp", agent: "sh",
            argv: ["/bin/sh", "-c", "printf 'pick:\\n  1. yes\\n  2. no\\n'; exec cat"],
            name: "menu")
        let (model, _) = try makeModel(daemon)
        await model.start()
        let rendered = await eventually {
            daemon.registry.snapshotScreens()["menu"]?.contains("2. no") == true
        }
        XCTAssertTrue(rendered)
        daemon.monitor.tick()
        let updated = await eventually { model.statusByName["menu"] == .waiting }
        XCTAssertTrue(updated, "statusChanged did not land in model")
        daemon.registry.kill(name: "menu")
    }

    @MainActor
    func testModelChangedUpdatesMap() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let uuid = "0b154175-0f2e-43e8-b5b0-97ec3cb0e6a4"
        try FileManager.default.createDirectory(atPath: "\(daemon.modelRoot)/-tmp",
                                                withIntermediateDirectories: true)
        try #"{"type":"assistant","message":{"model":"claude-fable-5"}}"#
            .write(toFile: "\(daemon.modelRoot)/-tmp/\(uuid).jsonl",
                   atomically: true, encoding: .utf8)
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"],
                                       name: "s", resumeCmd: "claude --resume \(uuid)")
        let (model, _) = try makeModel(daemon)
        await model.start()
        daemon.modelMonitor.tick()
        let updated = await eventually { model.modelByName["s"] == "claude-fable-5" }
        XCTAssertTrue(updated, "modelChanged did not land in model")
        daemon.registry.kill(name: "s")
    }

    @MainActor
    func testStartSelectsFirstSession() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "sh",
                                       argv: ["/bin/cat"], name: "first")
        let (model, _) = try makeModel(daemon)
        await model.start()
        XCTAssertEqual(model.selected, "first",
                       "launch lands on the first session, not on a placeholder")
        daemon.registry.kill(name: "first")
    }

    @MainActor
    func testCreateFullSelectsAndFocusesNewSession() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        let err = await model.createFull(name: "fresh", dir: "/usr", agent: "/bin/cat",
                                         terminal: false, worktree: nil,
                                         model: nil, effort: nil)
        XCTAssertNil(err)
        XCTAssertEqual(model.selected, "fresh")
        XCTAssertEqual(model.focusedPane, "fresh")
        XCTAssertEqual(model.focus, .terminal)
        await model.kill("fresh")
    }

    @MainActor
    func testKillRemovesSessionAndClearsSelection() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/usr", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = model.sessions[0].name
        await model.select(name)
        XCTAssertEqual(model.selected, name)
        await model.kill(name)
        let gone = await eventually { model.sessions.isEmpty && model.selected == nil }
        XCTAssertTrue(gone)
    }

    @MainActor
    func testOutputRoutesOnlyForSelectedSession() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/usr", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let a = model.sessions[0].name
        await model.select(a)

        var received: [UInt8] = []
        model.setTerminalSink(for: a) { received.append(contentsOf: $0) }
        await model.sendInput(Array("ping\n".utf8), to: a)
        let got = await eventually {
            String(decoding: received, as: UTF8.self).contains("ping")
        }
        XCTAssertTrue(got, "selected session's output did not reach the terminal callback")
        await model.kill(a)
    }

    // Bug 7 regression: attach backfill can arrive before the terminal view
    // mounts its sink. Those bytes must buffer and flush when the sink appears.
    @MainActor
    func testOutputBuffersUntilSinkMountsThenFlushes() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/usr", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let a = model.sessions[0].name
        await model.select(a)                       // no sink set yet
        await model.sendInput(Array("marker\n".utf8), to: a)
        // Let the echo round-trip and buffer while no sink is attached.
        try await Task.sleep(nanoseconds: 300_000_000)
        var received = ""
        model.setTerminalSink(for: a) { received += String(decoding: $0, as: UTF8.self) }
        let flushed = await eventually { received.contains("marker") }
        XCTAssertTrue(flushed, "buffered output did not flush to the late sink")
        await model.kill(a)
    }

    // Bug 8 regression: reconnecting to a fresh daemon that lost the sessions must
    // clear the stale selection silently — no "not found" toast from re-attach.
    @MainActor
    func testReconnectToFreshDaemonClearsSelectionWithoutToast() async throws {
        let daemon1 = try TestDaemon()
        let daemon2 = try TestDaemon()          // the "respawned" empty daemon
        defer { daemon1.stop(); daemon2.stop() }
        let client = IPCClient(path: daemon1.path)
        try client.connect()
        let p2 = daemon2.path
        let statePath = "\(NSTemporaryDirectory())covey-recon-\(UInt32.random(in: 0..<UInt32.max)).json"
        let model = AppModel(
            client: client,
            makeClient: { let c = IPCClient(path: p2); try c.connect(); return c },
            store: StateStore(path: statePath, debounce: 0.05))
        await model.start()
        await model.create(dir: "/usr", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        await model.select(model.sessions[0].name)
        XCTAssertNotNil(model.selected)

        daemon1.stop()                          // connection drops
        _ = await eventually { !model.connected }
        await model.reconnect()                 // connects to empty daemon2

        XCTAssertTrue(model.connected)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertNil(model.selected, "stale selection not cleared")
        XCTAssertNil(model.toast, "spurious toast after reconnect")
    }

    @MainActor
    func testExitedPushesRecentWithDirAndAgent() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/usr", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = model.sessions[0].name
        daemon.gitMonitor.onGitChanged?(
            name, GitInfo(branch: "feature/recent-search", added: 0, removed: 0))
        _ = await eventually {
            model.sessions.first(where: { $0.name == name })?.git?.branch
                == "feature/recent-search"
        }
        await model.kill(name)                        // -> .exited
        let recorded = await eventually { model.recents.contains { $0.name == name } }
        XCTAssertTrue(recorded)
        let r = model.recents.first { $0.name == name }
        XCTAssertEqual(r?.dir, "/usr")
        XCTAssertEqual(r?.agent, "/bin/cat")
        XCTAssertEqual(r?.branch, "feature/recent-search")
    }

    @MainActor
    func testRenameDoesNotPushRecent() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/usr", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = model.sessions[0].name
        await model.rename(name, to: "renamed")       // -> sessionRemoved + sessionAdded
        _ = await eventually { model.sessions.contains { $0.name == "renamed" } }
        XCTAssertFalse(model.recents.contains { $0.name == name },
                       "rename must not create a recent")
        await model.kill("renamed")
    }

    @MainActor
    func testIssueBindingSurvivesRename() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/usr", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = model.sessions[0].name
        model.bindIssue(297111, toSession: name)
        XCTAssertEqual(model.issueNumber(forSession: name), 297111)
        await model.rename(name, to: "renamed")
        _ = await eventually { model.sessions.contains { $0.name == "renamed" } }
        XCTAssertEqual(model.issueNumber(forSession: "renamed"), 297111,
                       "issue binding migrates to the new name")
        XCTAssertNil(model.issueNumber(forSession: name), "old name is no longer bound")
        await model.kill("renamed")
    }

    @MainActor
    func testRelaunchRecentCanRestoreWithoutActivating() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        let r = RecentSession(name: "back", dir: "/usr", agent: "/bin/cat")
        let restored = await model.relaunchRecent(r, activate: false)
        XCTAssertTrue(restored)
        let appeared = await eventually { model.sessions.contains { $0.name == "back" } }
        XCTAssertTrue(appeared)
        XCTAssertNil(model.selected)
        XCTAssertEqual(model.focus, .sessions)
        await model.kill("back")
    }

    @MainActor
    func testRelaunchRecentActivatesByDefaultAndReportsFailure() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        let r = RecentSession(name: "back", dir: "/usr", agent: "/bin/cat")
        let restored = await model.relaunchRecent(r)
        XCTAssertTrue(restored)
        let selected = await eventually { model.selected == "back" }
        XCTAssertTrue(selected)
        XCTAssertEqual(model.focus, .terminal)
        let duplicate = await model.relaunchRecent(r, activate: false)
        XCTAssertFalse(duplicate)
        XCTAssertNotNil(model.toast)
        await model.kill("back")
    }

    @MainActor
    func testSetThemeAndSplitPersistToStore() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-appstate-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 0.05)
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(client: client,
                             makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                             store: store)
        await model.start()
        model.setTheme("light")
        model.setSplitPct(25)
        store.flush()
        let reloaded = store.load()
        XCTAssertEqual(reloaded.theme, "light")
        XCTAssertEqual(reloaded.splitPct, 25)
    }

    @MainActor
    func testStartAppliesPersistedThemeSplitRecents() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-appstate-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Pre-seed a state file.
        var seed = PersistedState(theme: "light", splitPct: 33)
        seed.recents = [RecentSession(name: "old", dir: "/w", agent: "sh")]
        let store0 = StateStore(path: path, debounce: 0.01)
        store0.save(seed); store0.flush()

        let store = StateStore(path: path, debounce: 0.05)
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(client: client,
                             makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                             store: store)
        await model.start()
        XCTAssertEqual(model.themeRaw, "light")
        XCTAssertEqual(model.splitPct, 33)
        XCTAssertEqual(model.recents.map(\.name), ["old"])
    }

    @MainActor
    func testClientCloseFlipsConnectedAndSetsToast() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, client) = try makeModel(daemon)
        await model.start()
        XCTAssertTrue(model.connected)
        client.close()
        let dropped = await eventually { !model.connected && model.toast != nil }
        XCTAssertTrue(dropped, "stream end did not flip connected/toast")
    }

    @MainActor
    func testLostSessionsMergeIntoRecentsOnce() async throws {
        let meta = SessionMeta(name: "lost1", dir: "/tmp", agent: "claude",
                               argv: ["claude"], created: 1)
        let daemon = try TestDaemon(persisted: [meta]); defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-lost-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 0.05)
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(client: client,
                             makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                             store: store)
        await model.start()
        XCTAssertNil(model.recents.first(where: { $0.name == "lost1" })?.branch,
                     "daemon-lost metadata has no live GitInfo")
        XCTAssertTrue(model.recents.contains { $0.name == "lost1" && $0.agent == "claude" })
        store.flush()
        XCTAssertTrue(store.load().recents.contains { $0.name == "lost1" })
        // clearLost was acked: a reconnect must not resurface the session.
        await model.reconnect()
        XCTAssertEqual(model.recents.filter { $0.name == "lost1" }.count, 1)
    }

    @MainActor
    func testBranchStatusAndKillDeleteBranch() async throws {
        let repo = "\(NSTemporaryDirectory())covey-am-del-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        for cmd in ["git -C '\(repo)' init -q -b main",
                    "git -C '\(repo)' -c user.email=t@t -c user.name=t commit --allow-empty -q -m init"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            try p.run(); p.waitUntilExit()
        }
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(
            dir: try {
                let pr = try CreateService.prepare(CreateSpec(
                    dir: repo, agent: "sh", worktree: .new(branch: "feat", base: "main")))
                return pr.finalDir
            }(),
            agent: "sh", argv: ["/bin/cat"], name: "wt", worktreeRepo: repo)
        let (model, _) = try makeModel(daemon)

        let st = await model.branchStatus(name: "wt")
        XCTAssertEqual(st?.dirty, false)
        XCTAssertEqual(st?.merged, true)

        await model.kill("wt", removeWorktree: false, deleteBranch: true)
        // deleteBranch implies worktree removal, then branch delete.
        let deadline = Date().addingTimeInterval(5)
        while GitOps.branchExists(repo, "feat") && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(GitOps.branchExists(repo, "feat"), "branch deleted via kill")
    }
}
