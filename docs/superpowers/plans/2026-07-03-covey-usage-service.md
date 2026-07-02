# covey Usage Service (Slice 7) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show Claude subscription usage (5h/7d windows + plan badge) in the terminal-pane header, polled in the background from the OAuth API.

**Architecture:** Pure parsers + model (`Usage.swift`), token retrieval from file/keychain (`Credentials.swift`), an async URLSession fetch (`UsageService.swift`), an AppModel poller with an injectable fetcher (so state is testable without network), and a `UsageChip` view shown only for Claude sessions. Spec: `docs/superpowers/specs/2026-07-03-covey-usage-service-design.md`.

**Tech Stack:** Swift 6.3 / SwiftPM, `swiftLanguageMode(.v5)`, macOS 26, SwiftUI, URLSession (async), `Process` for the `security` keychain read, XCTest. No new external dependencies.

## Global Constraints

- All code, comments, and string literals in English (docs/ excepted).
- Git write operations are performed BY THE USER; each task ends with the exact command.
- No network or thread `sleep` in tests; the usage fetcher is injected as a closure and the poll interval is injectable + short.
- Closures on queues/tasks capture `self` via `[weak self]` where they outlive the call.
- Exact Claude OAuth headers (from `usage.rs`): `Authorization: Bearer <token>`,
  `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/1.0.0` (mandatory — its
  absence causes persistent 429s), request timeout 10 s.
- Keychain read via shell `security find-generic-password -s "Claude Code-credentials" -w`.
- All usage-related code lives in the `covey` target (GUI-only). Tests in `CoveyAppTests`.
- Test run: `swift build --build-tests`, then
  `xcrun xctest -XCTest CoveyAppTests.<Class> .build/arm64-apple-macosx/debug/coveyPackageTests.xctest`.

---

### Task 1: Usage model + parsers

**Files:**
- Create: `Sources/covey/Usage.swift`
- Test: `Tests/CoveyAppTests/UsageParseTests.swift`

**Interfaces:**
- Produces (used by Tasks 3–4):
  - `struct UsageWindow: Equatable { var utilization: Double; var resetUnix: Int64?; var resetHHMM: String? }`
  - `struct Usage: Equatable { var fiveHour, sevenDay, sevenDaySonnet: UsageWindow?; var isEmpty: Bool }`
  - `struct Account: Equatable { var usage: Usage?; var plan: String?; var usageError: String? }`
  - `func parseUsage(_ body: Data) -> Usage?`
  - `func parsePlan(_ body: Data) -> String?`
  - `func planLabel(_ tier: String) -> String`
  - `func parseISO8601(_ s: String) -> Int64?`

- [ ] **Step 1: Write the compilable skeleton**

`Sources/covey/Usage.swift`:

```swift
import Foundation

public struct UsageWindow: Equatable {
    public var utilization: Double     // 0–100
    public var resetUnix: Int64?       // reset instant, from `resets_at`
    public var resetHHMM: String?      // local HH:mm, filled by fetchAccount
}

public struct Usage: Equatable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var sevenDaySonnet: UsageWindow?
    public var isEmpty: Bool { fiveHour == nil && sevenDay == nil && sevenDaySonnet == nil }
}

public struct Account: Equatable {
    public var usage: Usage?
    public var plan: String?
    public var usageError: String?
    public init(usage: Usage? = nil, plan: String? = nil, usageError: String? = nil) {
        self.usage = usage; self.plan = plan; self.usageError = usageError
    }
}

/// Parses the `/api/oauth/usage` body. `resetHHMM` is NOT formatted here (see
/// fetchAccount). Returns nil if unusable or all windows are null.
func parseUsage(_ body: Data) -> Usage? {
    nil
}

/// `organization.rate_limit_tier` -> short badge; nil if absent.
func parsePlan(_ body: Data) -> String? {
    nil
}

/// Slug -> badge: base (Max/Pro/Team/Enterprise/Claude) + trailing `_Nx` -> "N×".
func planLabel(_ tier: String) -> String {
    "Claude"
}

/// ISO8601 (e.g. "2026-06-02T10:40:01Z") -> Unix seconds, or nil.
func parseISO8601(_ s: String) -> Int64? {
    nil
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/CoveyAppTests/UsageParseTests.swift`:

```swift
import XCTest
@testable import covey

final class UsageParseTests: XCTestCase {
    func testParseUsageExtractsWindows() {
        let body = Data(#"""
        {"five_hour": {"utilization": 77.0, "resets_at": "2026-06-02T10:40:01Z"},
         "seven_day": {"utilization": 40.0, "resets_at": null},
         "seven_day_sonnet": null}
        """#.utf8)
        let u = parseUsage(body)!
        XCTAssertEqual(u.fiveHour?.utilization, 77.0)
        XCTAssertEqual(u.fiveHour?.resetUnix, parseISO8601("2026-06-02T10:40:01Z"))
        XCTAssertEqual(u.sevenDay?.utilization, 40.0)
        XCTAssertNil(u.sevenDay?.resetUnix)
        XCTAssertNil(u.sevenDaySonnet)
    }

    func testParseUsageAllNullReturnsNil() {
        let body = Data(#"{"five_hour": null, "seven_day": null, "seven_day_sonnet": null}"#.utf8)
        XCTAssertNil(parseUsage(body))
    }

    func testParseUsageGarbageReturnsNil() {
        XCTAssertNil(parseUsage(Data("not json".utf8)))
    }

    func testParsePlan() {
        XCTAssertEqual(parsePlan(Data(#"{"organization": {"rate_limit_tier": "default_claude_max_5x"}}"#.utf8)), "Max 5×")
        XCTAssertNil(parsePlan(Data("{}".utf8)))
    }

    func testPlanLabel() {
        XCTAssertEqual(planLabel("default_claude_max_5x"), "Max 5×")
        XCTAssertEqual(planLabel("claude_pro"), "Pro")
        XCTAssertEqual(planLabel("some_team_plan"), "Team")
        XCTAssertEqual(planLabel("enterprise_thing"), "Enterprise")
        XCTAssertEqual(planLabel("weird"), "Claude")
    }

    func testParseISO8601() {
        // Compare against a Foundation-computed reference (no magic epoch number).
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 2; c.hour = 10; c.minute = 40; c.second = 1
        c.timeZone = TimeZone(identifier: "UTC")
        let expected = Int64(Calendar(identifier: .gregorian).date(from: c)!.timeIntervalSince1970)
        XCTAssertEqual(parseISO8601("2026-06-02T10:40:01Z"), expected)
        XCTAssertNil(parseISO8601("nonsense"))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveyAppTests.UsageParseTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
```

Expected: 6 tests, ≥5 failures.

- [ ] **Step 4: Implement**

Replace the stub bodies in `Sources/covey/Usage.swift`:

```swift
func parseUsage(_ body: Data) -> Usage? {
    guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        return nil
    }
    func window(_ key: String) -> UsageWindow? {
        guard let w = root[key] as? [String: Any],
              let util = w["utilization"] as? Double else { return nil }
        let resetUnix = (w["resets_at"] as? String).flatMap(parseISO8601)
        return UsageWindow(utilization: util, resetUnix: resetUnix, resetHHMM: nil)
    }
    let usage = Usage(fiveHour: window("five_hour"),
                      sevenDay: window("seven_day"),
                      sevenDaySonnet: window("seven_day_sonnet"))
    return usage.isEmpty ? nil : usage
}

func parsePlan(_ body: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let org = root["organization"] as? [String: Any],
          let tier = org["rate_limit_tier"] as? String else { return nil }
    return planLabel(tier)
}

func planLabel(_ tier: String) -> String {
    let t = tier.lowercased()
    let base: String
    if t.contains("max") { base = "Max" }
    else if t.contains("pro") { base = "Pro" }
    else if t.contains("team") { base = "Team" }
    else if t.contains("enterprise") { base = "Enterprise" }
    else { base = "Claude" }
    // A trailing "_<n>x" segment is the rate multiplier.
    let mult = t.split(separator: "_").reversed().compactMap { seg -> String? in
        guard seg.hasSuffix("x") else { return nil }
        let digits = seg.dropLast()
        return (!digits.isEmpty && digits.allSatisfy(\.isNumber)) ? String(digits) : nil
    }.first
    return mult.map { "\(base) \($0)×" } ?? base
}

func parseISO8601(_ s: String) -> Int64? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    guard let date = f.date(from: s) else { return nil }
    return Int64(date.timeIntervalSince1970)
}
```

- [ ] **Step 5: Run tests to verify they pass**

Same command as Step 3. Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 6: Hand off commit to the user**

```bash
git add Sources/covey/Usage.swift Tests/CoveyAppTests/UsageParseTests.swift
git commit -m "feat(covey): usage model + OAuth body parsers"
```

---

### Task 2: Credentials (file + keychain)

**Files:**
- Create: `Sources/covey/Credentials.swift`
- Test: `Tests/CoveyAppTests/CredentialsTests.swift`

**Interfaces:**
- Produces (used by Task 3):
  - `struct RawCredentials: Equatable { var accessToken: String; var expiresAtMs: Int64? }`
  - `func credentialsFromJSON(_ s: String) -> RawCredentials?`
  - `func readToken() -> String?`

- [ ] **Step 1: Write the compilable skeleton**

`Sources/covey/Credentials.swift`:

```swift
import Foundation

struct RawCredentials: Equatable {
    var accessToken: String
    var expiresAtMs: Int64?
    var isExpired: Bool {
        guard let expiresAtMs else { return false }
        return Double(expiresAtMs) < Date().timeIntervalSince1970 * 1000
    }
}

/// Parses `{"claudeAiOauth":{"accessToken":...,"expiresAt":<ms>}}`.
func credentialsFromJSON(_ s: String) -> RawCredentials? {
    nil
}

/// OAuth access token from `~/.claude/.credentials.json` or the keychain
/// (`security find-generic-password -s "Claude Code-credentials" -w`). Prefers a
/// non-expired source; when both are valid, prefers the keychain (Claude Code
/// refreshes it in place). If everything is expired, still returns something so
/// the API can answer 401 rather than a silent "no auth".
func readToken() -> String? {
    nil
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/CoveyAppTests/CredentialsTests.swift`:

```swift
import XCTest
@testable import covey

final class CredentialsTests: XCTestCase {
    func testExtractsToken() {
        let c = credentialsFromJSON(#"{"claudeAiOauth": {"accessToken": "sk-abc", "refreshToken": "x"}}"#)
        XCTAssertEqual(c?.accessToken, "sk-abc")
        XCTAssertNil(c?.expiresAtMs)
    }

    func testExtractsExpiry() {
        let c = credentialsFromJSON(#"{"claudeAiOauth": {"accessToken": "tok", "expiresAt": 1780000000000}}"#)
        XCTAssertEqual(c?.expiresAtMs, 1780000000000)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(credentialsFromJSON("not json"))
        XCTAssertNil(credentialsFromJSON(#"{"other": 1}"#))
    }

    func testIsExpired() {
        XCTAssertTrue(RawCredentials(accessToken: "t", expiresAtMs: 1).isExpired)          // 1970
        XCTAssertFalse(RawCredentials(accessToken: "t", expiresAtMs: nil).isExpired)       // unknown -> not expired
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveyAppTests.CredentialsTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
```

Expected: 4 tests, ≥3 failures (isExpired may pass off the skeleton struct).

- [ ] **Step 4: Implement**

Replace the two stub functions in `Sources/covey/Credentials.swift`:

```swift
func credentialsFromJSON(_ s: String) -> RawCredentials? {
    guard let data = s.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String else { return nil }
    let expires = (oauth["expiresAt"] as? NSNumber)?.int64Value
    return RawCredentials(accessToken: token, expiresAtMs: expires)
}

func readToken() -> String? {
    let fromFile: RawCredentials? = {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let s = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        return credentialsFromJSON(s)
    }()
    let fromKeychain: RawCredentials? = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return credentialsFromJSON(String(decoding: data, as: UTF8.self))
    }()
    // Prefer a non-expired source; keychain wins ties (refreshed in place).
    switch (fromFile, fromKeychain) {
    case let (_, k?) where !k.isExpired: return k.accessToken
    case let (f?, _) where !f.isExpired: return f.accessToken
    case let (_, k?): return k.accessToken
    case let (f?, nil): return f.accessToken
    case (nil, nil): return nil
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Same command as Step 3. Expected: `Executed 4 tests, with 0 failures`.
(`readToken` is exercised by the Task 4 manual smoke, not a unit test — it touches the
real keychain/file.)

- [ ] **Step 6: Hand off commit to the user**

```bash
git add Sources/covey/Credentials.swift Tests/CoveyAppTests/CredentialsTests.swift
git commit -m "feat(covey): OAuth token from credentials file + keychain"
```

---

### Task 3: UsageService + AppModel poller

**Files:**
- Create: `Sources/covey/UsageService.swift`
- Modify: `Sources/covey/AppModel.swift`
- Modify: `Sources/covey/App.swift` (inject the real fetcher)
- Test: `Tests/CoveyAppTests/AppModelUsageTests.swift`

**Interfaces:**
- Consumes: `Account`/`Usage`/`parseUsage`/`parsePlan` (Task 1), `readToken` (Task 2).
- Produces (used by Task 4):
  - `enum UsageService { static func fetchAccount() async -> Account; static func oauthGet(_ path: String) async -> Result<Data, String> }`
  - `AppModel(client:makeClient:store:fetchAccount:usageInterval:)` — the two new params
    default to a no-op fetcher and 60 s, so existing call sites compile unchanged.
  - `AppModel.usage: Usage?`, `.plan: String?`, `.usageError: String?`

- [ ] **Step 1: UsageService**

`Sources/covey/UsageService.swift`:

```swift
import Foundation

enum UsageService {
    /// One poll cycle: usage and plan fetched independently (partial success ok).
    static func fetchAccount() async -> Account {
        var acc = Account()
        switch await oauthGet("/api/oauth/usage") {
        case .success(let body):
            if var usage = parseUsage(body) {
                fillResetTimes(&usage)
                acc.usage = usage
            } else {
                acc.usageError = "parse"
            }
        case .failure(let code):
            acc.usageError = code
        }
        if case .success(let body) = await oauthGet("/api/oauth/profile") {
            acc.plan = parsePlan(body)
        }
        return acc
    }

    /// GET an OAuth endpoint with the stored token and Claude Code headers.
    static func oauthGet(_ path: String) async -> Result<Data, String> {
        guard let token = readToken() else { return .failure("no auth") }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com\(path)")!)
        req.timeoutInterval = 10
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/1.0.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return .failure("\(status)") }
            return .success(data)
        } catch {
            return .failure("net")
        }
    }

    /// Format each window's `resetUnix` into a local HH:mm string.
    private static func fillResetTimes(_ usage: inout Usage) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        func fmt(_ w: inout UsageWindow?) {
            guard var win = w, let unix = win.resetUnix else { return }
            win.resetHHMM = f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
            w = win
        }
        fmt(&usage.fiveHour); fmt(&usage.sevenDay); fmt(&usage.sevenDaySonnet)
    }
}
```

- [ ] **Step 2: Write the failing AppModel tests**

`Tests/CoveyAppTests/AppModelUsageTests.swift`:

```swift
import XCTest
@testable import covey
import CoveyKit

final class AppModelUsageTests: XCTestCase {
    @MainActor
    private func makeUsageModel(_ daemon: TestDaemon,
                                fetch: @escaping () async -> Account,
                                interval: TimeInterval = 0.05) throws -> AppModel {
        let client = IPCClient(path: daemon.path); try client.connect()
        let statePath = "\(NSTemporaryDirectory())covey-usage-\(UInt32.random(in: 0..<UInt32.max)).json"
        return AppModel(
            client: client,
            makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
            store: StateStore(path: statePath, debounce: 0.05),
            fetchAccount: fetch,
            usageInterval: interval)
    }

    @MainActor
    func testPollerAppliesUsageAndPlan() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let acc = Account(usage: Usage(fiveHour: UsageWindow(utilization: 55, resetUnix: nil, resetHHMM: nil),
                                       sevenDay: nil, sevenDaySonnet: nil),
                          plan: "Max 5×", usageError: nil)
        let model = try makeUsageModel(daemon, fetch: { acc })
        await model.start()
        let ok = await eventually { model.usage?.fiveHour?.utilization == 55 && model.plan == "Max 5×" }
        XCTAssertTrue(ok)
        XCTAssertNil(model.usageError)
    }

    @MainActor
    func testPollerAppliesPartialError() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try makeUsageModel(daemon, fetch: { Account(usageError: "429") })
        await model.start()
        let ok = await eventually { model.usageError == "429" }
        XCTAssertTrue(ok)
        XCTAssertNil(model.usage)
    }

    @MainActor
    func testPollerRefreshesOnNextTick() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let box = AccountBox()
        box.value = Account(usageError: "net")
        let model = try makeUsageModel(daemon, fetch: { box.value })
        await model.start()
        _ = await eventually { model.usageError == "net" }
        box.value = Account(plan: "Pro")
        let refreshed = await eventually { model.plan == "Pro" && model.usageError == nil }
        XCTAssertTrue(refreshed)
    }
}

/// Mutable holder so the fetch closure can return changing values across ticks.
final class AccountBox: @unchecked Sendable { var value = Account() }
```

- [ ] **Step 3: Run tests to verify they fail to compile**

```bash
swift build --build-tests 2>&1 | grep -E "error:" | head -5
```

Expected: errors — `AppModel` has no `fetchAccount:`/`usageInterval:` params, no
`usage`/`plan`/`usageError`.

- [ ] **Step 4: Implement the AppModel changes**

In `Sources/covey/AppModel.swift`:

1. Add state after `recents`:

```swift
    public private(set) var usage: Usage?
    public private(set) var plan: String?
    public private(set) var usageError: String?
```

2. Add stored fetcher + interval + task, near `private let store`:

```swift
    private let fetchAccount: () async -> Account
    private let usageInterval: TimeInterval
    private var usagePoller: Task<Void, Never>?
```

3. Replace the initializer:

```swift
    public init(client: IPCClient,
                makeClient: @escaping () throws -> IPCClient,
                store: StateStore,
                fetchAccount: @escaping () async -> Account = { Account() },
                usageInterval: TimeInterval = 60) {
        self.client = client
        self.makeClient = makeClient
        self.store = store
        self.fetchAccount = fetchAccount
        self.usageInterval = usageInterval
    }
```

4. At the end of `start()` (after the event loop is created), launch the poller:

```swift
        usagePoller?.cancel()
        usagePoller = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tickUsage()
                try? await Task.sleep(nanoseconds: UInt64(self.usageInterval * 1_000_000_000))
            }
        }
```

5. Add `tickUsage` in the private section:

```swift
    private func tickUsage() async {
        let acc = await fetchAccount()
        usage = acc.usage
        plan = acc.plan
        usageError = acc.usageError
    }
```

In `Sources/covey/App.swift`, pass the real fetcher when constructing the model:

```swift
                    let m = AppModel(client: try CoveyApp.makeClient(),
                                     makeClient: CoveyApp.makeClient,
                                     store: store,
                                     fetchAccount: UsageService.fetchAccount)
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveyAppTests.AppModelUsageTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
```

Expected: `Executed 3 tests, with 0 failures`. Then the full suite:

```bash
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1
```

Expected: 0 failures (prior tests still green — their models use the default no-op fetcher).

- [ ] **Step 6: Hand off commit to the user**

```bash
git add Sources/covey/UsageService.swift Sources/covey/AppModel.swift Sources/covey/App.swift Tests/CoveyAppTests/AppModelUsageTests.swift
git commit -m "feat(covey): usage service + background poller"
```

---

### Task 4: UsageChip + header wiring + smoke

**Files:**
- Create: `Sources/covey/Views/UsageChip.swift`
- Modify: `Sources/covey/Views/TerminalPaneView.swift`
- Test: `Tests/CoveyAppTests/UsageChipTests.swift`

**Interfaces:**
- Consumes: `Usage`/`UsageWindow` (Task 1), `AppModel.usage/plan/usageError` (Task 3).
- Produces: the chip view + a pure `windowLabel`/`isClaudeAgent` helper.

- [ ] **Step 1: Write the failing helper tests**

`Tests/CoveyAppTests/UsageChipTests.swift`:

```swift
import XCTest
@testable import covey

final class UsageChipTests: XCTestCase {
    func testWindowLabelRoundsPercent() {
        let w = UsageWindow(utilization: 76.6, resetUnix: nil, resetHHMM: nil)
        XCTAssertEqual(windowLabel("5h", w), "5h 77%")
    }

    func testWindowLabelIncludesResetWhenPresent() {
        let w = UsageWindow(utilization: 40, resetUnix: nil, resetHHMM: "10:40")
        XCTAssertEqual(windowLabel("7d", w), "7d 40% · 10:40")
    }

    func testIsClaudeAgent() {
        XCTAssertTrue(isClaudeAgent("claude"))
        XCTAssertTrue(isClaudeAgent("/usr/local/bin/Claude"))
        XCTAssertFalse(isClaudeAgent("sh"))
        XCTAssertFalse(isClaudeAgent("/bin/cat"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail to compile**

```bash
swift build --build-tests 2>&1 | grep -E "error:" | head -3
```

Expected: errors — `windowLabel`/`isClaudeAgent` undefined.

- [ ] **Step 3: Implement the chip + helpers**

`Sources/covey/Views/UsageChip.swift`:

```swift
import SwiftUI

/// "5h 77%" or "7d 40% · 10:40" (with reset time when known).
func windowLabel(_ prefix: String, _ w: UsageWindow) -> String {
    let pct = Int(w.utilization.rounded())
    if let reset = w.resetHHMM { return "\(prefix) \(pct)% · \(reset)" }
    return "\(prefix) \(pct)%"
}

/// Whether the chip applies to this session's agent (Claude only).
func isClaudeAgent(_ agent: String) -> Bool {
    agent.lowercased().contains("claude")
}

/// Compact Claude usage chip: windows + plan badge, or an error code.
struct UsageChip: View {
    let usage: Usage?
    let plan: String?
    let error: String?

    var body: some View {
        if let usage {
            HStack(spacing: 8) {
                if let w = usage.fiveHour { pill(windowLabel("5h", w)) }
                if let w = usage.sevenDay { pill(windowLabel("7d", w)) }
                if let w = usage.sevenDaySonnet { pill(windowLabel("S 7d", w)) }
                if let plan { pill(plan).foregroundStyle(.secondary) }
            }
            .font(.caption)
        } else if let error {
            Text("usage: \(error)").font(.caption).foregroundStyle(.orange)
        } else {
            EmptyView()
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}
```

- [ ] **Step 4: Show the chip in the terminal header**

In `Sources/covey/Views/TerminalPaneView.swift`, add the chip to `header` for Claude
sessions. Replace the `header` function:

```swift
    private func header(_ session: Session) -> some View {
        HStack(spacing: 8) {
            Text(session.name).fontWeight(.semibold)
            Text(session.dir).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if isClaudeAgent(session.agent) {
                UsageChip(usage: model.usage, plan: model.plan, error: model.usageError)
            }
            Text(session.agent).foregroundStyle(.secondary).font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
```

- [ ] **Step 5: Run tests + full suite**

```bash
swift build --build-tests 2>&1 | grep -E "error|Build complete" | tail -2
xcrun xctest -XCTest CoveyAppTests.UsageChipTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1
```

Expected: `Build complete!`, 3 chip tests pass, full suite 0 failures.

- [ ] **Step 6: Manual smoke (Definition of Done, spec §10)**

```bash
pkill -f coveyd 2>/dev/null; rm -f ~/.covey/coveyd.sock
swift run covey
```

Verify in the app (needs a real Claude login on this machine):
1. New session with agent `claude` → header shows a usage chip (5h/7d %, plan badge)
   within ~a few seconds; it refreshes on the ~60 s poll.
2. New session with agent `sh` → no chip.
3. If you have no Claude creds (or they are expired), the chip shows an error code
   ("no auth" / "401") and the app does not crash.
4. `readToken` may trigger a one-time macOS keychain prompt — allow it.

Fix any failure inline (each fix = its own user commit) and re-check.

- [ ] **Step 7: Hand off commit to the user**

```bash
git add Sources/covey/Views/UsageChip.swift Sources/covey/Views/TerminalPaneView.swift Tests/CoveyAppTests/UsageChipTests.swift
git commit -m "feat(covey): Claude usage chip in terminal header"
```

---

## Definition of Done (from spec §10)

1. Build + all tests green (prior suite + Usage/Credentials/AppModel/Chip additions).
2. Claude session with valid creds → chip with 5h/7d windows + plan badge, refreshed in background.
3. No/expired creds → chip shows an error code; UI never crashes.
4. Non-Claude session (`sh`) → no chip.
5. Network/keychain failure only sets `usageError`, never crashes.
