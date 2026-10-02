import XCTest
import CoveyKit
@testable import CoveydCore

@MainActor
final class UsageMonitorTests: XCTestCase {
    func testRefreshPreservesCacheOnErrorAndRestoresDisabledFlag() async throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + "/usage.json"
        var calls = 0
        let monitor = UsageMonitor(path: path, legacyPath: path + ".legacy", fetchAccount: {
            calls += 1
            return calls == 1 ? Account(usage: Usage(fiveHour: UsageWindow(utilization: 42, resetUnix: 100), sevenDay: nil, sevenDaySonnet: nil), plan: "Pro") : Account(usageError: "net")
        }, resolveCodex: { nil })
        await monitor.refresh(.claude)
        await monitor.refresh(.claude)
        XCTAssertEqual(monitor.snapshot.usage?.fiveHour?.utilization, 42)
        XCTAssertEqual(monitor.snapshot.usageError, "net")
        try monitor.setEnabled(.claude, enabled: false)
        let restored = UsageMonitor(path: path, legacyPath: path + ".legacy", resolveCodex: { nil })
        XCTAssertFalse(restored.snapshot.claudeUsageEnabled)
        XCTAssertEqual(restored.snapshot.usage, monitor.snapshot.usage)
        XCTAssertEqual(restored.snapshot.revision, 0)
    }

    func testDisabledGenerationIgnoresInflightResult() async throws {
        let path = NSTemporaryDirectory() + UUID().uuidString
        var pending: CheckedContinuation<Account, Never>?
        let monitor = UsageMonitor(path: path, legacyPath: path + ".legacy", fetchAccount: {
            await withCheckedContinuation { pending = $0 }
        }, resolveCodex: { nil })
        let request = Task { await monitor.refresh(.claude) }
        while pending == nil { await Task.yield() }
        try monitor.setEnabled(.claude, enabled: false)
        try monitor.setEnabled(.claude, enabled: true)
        pending?.resume(returning: Account(plan: "stale"))
        await request.value
        XCTAssertNil(monitor.snapshot.plan)
    }

    func testMalformedPersistenceIsNotOverwritten() async throws {
        let path = NSTemporaryDirectory() + UUID().uuidString
        let original = Data("broken".utf8)
        try original.write(to: URL(fileURLWithPath: path))
        let monitor = UsageMonitor(path: path, legacyPath: path + ".legacy", fetchAccount: { Account(plan: "Pro") }, resolveCodex: { nil })
        await monitor.refresh(.claude)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
    }
    func testImportsLegacyOnlyWhenUsageFileAbsent() throws {
        let directory = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/usage.json"
        let legacyPath = directory + "/state.json"
        var legacy = PersistedState()
        legacy.claudeUsage = PersistedUsage(fiveHour: PersistedUsageWindow(utilization: 42))
        legacy.codexUsage = PersistedCodexUsage(primaryLabel: "5h", primary: PersistedUsageWindow(utilization: 10))
        legacy.codexPlan = "Pro"
        try JSONEncoder().encode(legacy).write(to: URL(fileURLWithPath: legacyPath))
        let monitor = UsageMonitor(path: path, legacyPath: legacyPath, resolveCodex: { nil })
        XCTAssertEqual(monitor.snapshot.usage?.fiveHour?.utilization, 42)
        XCTAssertEqual(monitor.snapshot.codexUsage?.primary?.label, "5h")
        XCTAssertEqual(monitor.snapshot.codexPlan, "Pro")
        legacy.claudePlan = "Old"
        try JSONEncoder().encode(legacy).write(to: URL(fileURLWithPath: legacyPath))
        XCTAssertNil(UsageMonitor(path: path, legacyPath: legacyPath).snapshot.plan)
    }

    func testPollingRunsWithoutSubscribersAndStops() async throws {
        var calls = 0
        var glmCalls = 0
        let monitor = UsageMonitor(fetchAccount: {
            calls += 1
            return Account(plan: "Plan \(calls)")
        }, fetchGLM: {
            glmCalls += 1
            return GLMAccount()
        }, usageInterval: 0.02, resolveCodex: { nil })
        monitor.start()
        for _ in 0..<100 where calls < 2 || glmCalls < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertGreaterThanOrEqual(calls, 2)
        XCTAssertGreaterThanOrEqual(glmCalls, 2, "GLM gets its own poller like Claude")
        monitor.stop()
        let count = calls
        let glmCount = glmCalls
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(calls, count)
        XCTAssertEqual(glmCalls, glmCount)
    }

    func testIdenticalRefreshDoesNotRepublishOrBumpRevision() async throws {
        let quota = GLMQuota(plan: "max", limits: GLMLimits(
            fiveHours: GLMLimitWindow(total: 28000, used: 5695, remaining: 22304,
                                      usedPercent: 20, remainingPercent: 80,
                                      resetAt: 1_790_943_951_592)))
        let monitor = UsageMonitor(fetchAccount: { Account() },
                                   fetchGLM: { GLMAccount(quota: quota) },
                                   resolveCodex: { nil })
        await monitor.refresh(.glm)
        let revision = monitor.snapshot.revision
        var published = 0
        monitor.onChange = { _ in published += 1 }
        await monitor.refresh(.glm)
        await monitor.refresh(.glm)
        XCTAssertEqual(monitor.snapshot.revision, revision,
                       "a byte-identical poll result is a no-op, not a rewrite")
        XCTAssertEqual(published, 0)
    }

    func testGLMRefreshCachesOnErrorAndPersistsToggle() async throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + "/usage.json"
        let quota = GLMQuota(plan: "max", limits: GLMLimits(
            fiveHours: GLMLimitWindow(total: 28000, used: 5695, remaining: 22304,
                                      usedPercent: 20, remainingPercent: 80,
                                      resetAt: 1_790_943_951_592)))
        var calls = 0
        let monitor = UsageMonitor(path: path, legacyPath: path + ".legacy", fetchAccount: { Account() },
                                   fetchGLM: {
            calls += 1
            return calls == 1 ? GLMAccount(quota: quota) : GLMAccount(error: "401")
        }, resolveCodex: { nil })
        await monitor.refresh(.glm)
        XCTAssertEqual(monitor.snapshot.glmQuota, quota)
        XCTAssertNil(monitor.snapshot.glmUsageError)
        await monitor.refresh(.glm)
        XCTAssertEqual(monitor.snapshot.glmQuota, quota, "error keeps the last good snapshot")
        XCTAssertEqual(monitor.snapshot.glmUsageError, "401")
        try monitor.setEnabled(.glm, enabled: false)
        await monitor.refresh(.glm)
        XCTAssertEqual(calls, 2, "disabled provider skips the fetch")
        let restored = UsageMonitor(path: path, legacyPath: path + ".legacy", fetchGLM: { GLMAccount() },
                                    resolveCodex: { nil })
        XCTAssertFalse(restored.snapshot.glmUsageEnabled)
        XCTAssertEqual(restored.snapshot.glmQuota, quota)
    }

    func testDisabledProvidersSkipFetchAndCodexUpdates() async throws {
        var calls = 0
        let monitor = UsageMonitor(fetchAccount: { calls += 1; return Account() }, resolveCodex: { nil })
        for provider in UsageProvider.allCases { try monitor.setEnabled(provider, enabled: false); await monitor.refresh(provider) }
        monitor.ingestRateLimits(CodexRateLimitsSnapshot(primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 80)), secondary: nil))
        XCTAssertEqual(calls, 0)
        XCTAssertNil(monitor.snapshot.codexUsage)
        XCTAssertEqual(monitor.snapshot.codexState, .stopped)
    }

    func testPreferenceWriteFailureDoesNotPublishOrChangePreference() throws {
        let directory = NSTemporaryDirectory() + UUID().uuidString
        try Data("not a directory".utf8).write(to: URL(fileURLWithPath: directory))
        let monitor = UsageMonitor(path: directory + "/usage.json", resolveCodex: { nil })
        var published = false
        monitor.onChange = { _ in published = true }
        XCTAssertThrowsError(try monitor.setEnabled(.claude, enabled: false))
        XCTAssertTrue(monitor.snapshot.claudeUsageEnabled)
        XCTAssertEqual(monitor.snapshot.revision, 0)
        XCTAssertFalse(published)
    }

    func testCodexMergeAndUnauthedCacheInvalidation() {
        let monitor = UsageMonitor(resolveCodex: { nil })
        monitor.ingestRateLimits(CodexRateLimitsSnapshot(primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 80)), secondary: nil))
        monitor.ingestRateLimits(CodexRateLimitsSnapshot(primary: nil, secondary: LabeledWindow(label: "7d", window: UsageWindow(utilization: 20))))
        monitor.setCodexState(.active(CodexAccount(type: "chatgpt", planType: "plus")))
        monitor.setCodexState(.stopped)
        XCTAssertEqual(monitor.snapshot.codexUsage?.primary?.window.utilization, 80)
        XCTAssertEqual(monitor.snapshot.codexUsage?.secondary?.window.utilization, 20)
        XCTAssertEqual(monitor.snapshot.codexPlan, "Plus")
        monitor.setCodexState(.unauthed)
        XCTAssertNil(monitor.snapshot.codexUsage)
        XCTAssertNil(monitor.snapshot.codexPlan)
    }

    func testCodexRefreshRequestsNewLimitsFromRunningServer() async throws {
        let path = NSTemporaryDirectory() + UUID().uuidString
        let script = """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
            case "$line" in
                *'"id":1'*) printf '%s\n' '{"id":1,"result":{}}' ;;
                *'"id":2'*) printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","planType":"plus"}}}' ;;
                *'"id":3'*) count=$((count + 1)); printf '{"id":3,"result":{"primary":{"usedPercent":%s,"windowDurationMins":300}}}\n' "$count" ;;
            esac
        done
        """
        try Data(script.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        let monitor = UsageMonitor(resolveCodex: { path })
        defer { monitor.stop() }
        await monitor.refresh(.codex)
        for _ in 0..<200 where monitor.snapshot.codexUsage == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(monitor.snapshot.codexUsage?.primary?.window.utilization, 1)
        await monitor.refresh(.codex)
        for _ in 0..<200 where monitor.snapshot.codexUsage?.primary?.window.utilization == 1 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(monitor.snapshot.codexUsage?.primary?.window.utilization, 2)
    }

    func testCodexHandshakeDoesNotForceTokenRefresh() async throws {
        let path = NSTemporaryDirectory() + UUID().uuidString
        let script = """
        #!/bin/sh
        while IFS= read -r line; do
            case "$line" in
                *'"id":1'*) printf '%s\n' '{"id":1,"result":{}}' ;;
                *'"id":2'*)
                    case "$line" in
                        *'"refreshToken":true'*) printf '%s\n' '{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}' ;;
                        *) printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","planType":"prolite"}}}' ;;
                    esac ;;
                *'"id":3'*) printf '%s\n' '{"id":3,"result":{"primary":{"usedPercent":17,"windowDurationMins":10080}}}' ;;
            esac
        done
        """
        try Data(script.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        let monitor = UsageMonitor(resolveCodex: { path })
        defer { monitor.stop() }
        await monitor.refresh(.codex)
        for _ in 0..<100 where monitor.snapshot.codexUsage == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(monitor.snapshot.codexUsage?.primary?.window.utilization, 17)
    }

    func testMissingCodexAccountClearsCachedLimits() async throws {
        let path = NSTemporaryDirectory() + UUID().uuidString
        let script = """
        #!/bin/sh
        while IFS= read -r line; do
            case "$line" in
                *'"id":1'*) printf '%s\n' '{"id":1,"result":{}}' ;;
                *'"id":2'*) printf '%s\n' '{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}' ;;
            esac
        done
        """
        try Data(script.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        var attempts = 0
        let monitor = UsageMonitor(fetchAccount: { Account() }, fetchGLM: { GLMAccount() },
                                   usageInterval: 0.02, resolveCodex: { attempts += 1; return path })
        defer { monitor.stop() }
        monitor.ingestRateLimits(CodexRateLimitsSnapshot(primary: LabeledWindow(label: "7d", window: UsageWindow(utilization: 100)), secondary: nil))
        await monitor.refresh(.codex)
        for _ in 0..<100 where monitor.snapshot.codexState != .unauthed { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(monitor.snapshot.codexState, .unauthed)
        XCTAssertNil(monitor.snapshot.codexUsage)
        monitor.start()
        for _ in 0..<100 where attempts < 3 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertGreaterThanOrEqual(attempts, 3, "Retry periodically so a later CLI login can recover")
    }

    func testFailedCodexSpawnRetriesOnNextPoll() async throws {
        var attempts = 0
        let monitor = UsageMonitor(fetchAccount: { Account() }, fetchGLM: { GLMAccount() }, usageInterval: 0.02, resolveCodex: {
            attempts += 1
            return "/nonexistent/covey-test-codex"
        })
        monitor.start()
        defer { monitor.stop() }
        for _ in 0..<100 where attempts < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertGreaterThanOrEqual(attempts, 2)
        XCTAssertEqual(monitor.snapshot.codexState, .stopped)
    }

}
