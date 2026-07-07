# Уведомления о лимитах usage (5h/7d ≥ 80%) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Системное macOS-уведомление, когда утилизация окна 5h или 7d впервые в цикле окна достигает 80%: какое окно, сколько осталось, через сколько сброс.

**Architecture:** GUI-only. Чистая функция `limitAlerts` (вход: `Usage` + маркеры, выход: алерты + новые маркеры) вызывается из существующего `AppModel.tickUsage()` (полл раз в 60с). Маркеры «уже уведомил» — `resetUnix` окна — персистятся в `PersistedState.usageNotified`, рестарт app повтора не даёт. Постинг — тонкий `Notifier` над `UNUserNotificationCenter`, no-op вне .app-бандла.

**Tech Stack:** Swift 6.3 / SwiftPM, SwiftUI + UserNotifications, XCTest.

## Global Constraints

- Спека: `docs/superpowers/specs/2026-07-07-covey-usage-limit-notifications-design.md`.
- Весь код и коммиты на английском; текст плана — русский.
- Git-операции записи выполняет ТОЛЬКО пользователь. Шаги «Чекпойнт» — предложить пользователю закоммитить с готовым сообщением и ждать.
- TDD-конвенция проекта: компилируемый скелет типа → падающий тест → реализация.
- `swift test` перед каждым чекпойнтом — 0 failures.
- Порог — константа `80.0`, та же граница, что `usageLevel .err` в `Sources/covey/Views/UsageChip.swift`. Не конфигурируется.
- Окно `sevenDaySonnet` НЕ уведомляется. Повторные пороги (90/100%), daemon-side вотчер, osascript-фолбэк — ВНЕ СКОУПА.
- `UNUserNotificationCenter` вне .app-бандла трапится (и в голом SPM-бинаре, и в xctest-хосте — у xctest bundleIdentifier ЕСТЬ, поэтому гард только по `Bundle.main.bundleURL.pathExtension == "app"`). Никаких прямых обращений к центру мимо `Notifier`.
- Демон (`Sources/CoveydCore`, `Sources/coveyd`) не трогается вообще.
- SourceKit-фантомам при кросс-модульных правках не верить — верить `swift build` / `swift test`.

---

### Task 1: PersistedState.usageNotified

**Files:**
- Modify: `Sources/CoveyKit/PersistedState.swift`
- Test: `Tests/CoveyKitTests/PersistedStateTests.swift`

**Interfaces:**
- Produces: `PersistedState.usageNotified: [String: Int64]?` — маркеры «уже уведомил»: ключ окна ("5h"/"7d") → `resetUnix` окна (0 — уведомили при отсутствующем `resets_at`). Optional: старый `state.json` декодится без миграции.

- [ ] **Step 1: Падающий тест** — в конец класса `PersistedStateTests`:

```swift
    func testUsageNotifiedRoundTripAndOmittedWhenNil() throws {
        var st = PersistedState()
        st.usageNotified = ["5h": 1_760_000_000, "7d": 0]
        let back = try JSONDecoder().decode(PersistedState.self,
                                            from: JSONEncoder().encode(st))
        XCTAssertEqual(back.usageNotified, ["5h": 1_760_000_000, "7d": 0])
        // Absent in old files: decodes to nil, encodes to nothing.
        let empty = try JSONDecoder().decode(PersistedState.self,
                                             from: JSONEncoder().encode(PersistedState()))
        XCTAssertNil(empty.usageNotified)
        let json = String(data: try JSONEncoder().encode(PersistedState()), encoding: .utf8)!
        XCTAssertFalse(json.contains("usageNotified"))
    }
```

- [ ] **Step 2: Прогнать — тест падает**

Run: `swift test --filter PersistedStateTests.testUsageNotifiedRoundTripAndOmittedWhenNil`
Expected: COMPILE FAIL — `value of type 'PersistedState' has no member 'usageNotified'`

- [ ] **Step 3: Реализация** — в `Sources/CoveyKit/PersistedState.swift`:

После поля `projects` (перед `lastVersion`) добавить:

```swift
    /// Usage-limit alert markers: window key ("5h"/"7d") -> resetUnix of the
    /// window cycle already alerted (0 when resets_at was absent).
    public var usageNotified: [String: Int64]?
```

В `init` добавить параметр (после `projects: [String]? = nil`):

```swift
        usageNotified: [String: Int64]? = nil,
```

и присваивание (после `self.projects = projects`):

```swift
        self.usageNotified = usageNotified
```

- [ ] **Step 4: Прогнать — тест зелёный**

Run: `swift test --filter PersistedStateTests`
Expected: PASS, 0 failures

- [ ] **Step 5: Чекпойнт** — предложить пользователю коммит:

```
feat(covey): persist usage-limit alert markers in state
```

---

### Task 2: LimitWatch — чистая логика алертов

**Files:**
- Create: `Sources/covey/LimitWatch.swift`
- Test: `Tests/CoveyAppTests/LimitWatchTests.swift`

**Interfaces:**
- Consumes: `Usage`, `UsageWindow` (`Sources/covey/Usage.swift`); `remainingLabel(resetUnix:now:)` (`Sources/covey/Views/UsageChip.swift`, internal — виден внутри модуля covey).
- Produces:
  - `struct LimitAlert: Equatable { let windowKey: String; let title: String; let body: String }`
  - `let limitAlertThreshold: Double` (= 80.0)
  - `func limitAlerts(usage: Usage, notified: [String: Int64], now: Date) -> (alerts: [LimitAlert], notified: [String: Int64])`

- [ ] **Step 1: Компилируемый скелет** — `Sources/covey/LimitWatch.swift`:

```swift
import Foundation

/// A system-notification payload for a usage window that crossed the
/// alert threshold.
struct LimitAlert: Equatable {
    let windowKey: String    // "5h" | "7d"
    let title: String        // "Claude 5h limit at 82%"
    let body: String         // "18% left · resets in 2h13m"
}

/// Same boundary as `usageLevel`'s .err tier.
let limitAlertThreshold = 80.0

/// Pure limit-crossing detector. `notified` maps a window key to the
/// resetUnix of the window cycle already alerted (0 when resets_at was
/// absent). Returns alerts to post plus the updated marker map.
func limitAlerts(usage: Usage, notified: [String: Int64], now: Date)
    -> (alerts: [LimitAlert], notified: [String: Int64]) {
    (alerts: [], notified: notified)
}
```

- [ ] **Step 2: Прогнать сборку**

Run: `swift build`
Expected: OK

- [ ] **Step 3: Падающие тесты** — `Tests/CoveyAppTests/LimitWatchTests.swift`:

```swift
import XCTest
@testable import covey

final class LimitWatchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func usage(five: UsageWindow? = nil, seven: UsageWindow? = nil,
                       sonnet: UsageWindow? = nil) -> Usage {
        Usage(fiveHour: five, sevenDay: seven, sevenDaySonnet: sonnet)
    }

    func testCrossingEmitsAlertAndMark() {
        let u = usage(five: UsageWindow(utilization: 82, resetUnix: 1_008_000))
        let (alerts, marks) = limitAlerts(usage: u, notified: [:], now: now)
        XCTAssertEqual(alerts.map(\.windowKey), ["5h"])
        XCTAssertEqual(marks, ["5h": 1_008_000])
    }

    func testSameWindowDeduped() {
        let u = usage(five: UsageWindow(utilization: 91, resetUnix: 1_008_000))
        let (alerts, marks) = limitAlerts(usage: u, notified: ["5h": 1_008_000], now: now)
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertEqual(marks, ["5h": 1_008_000])
    }

    func testNewResetCycleAlertsAgain() {
        let u = usage(five: UsageWindow(utilization: 85, resetUnix: 1_020_000))
        let (alerts, marks) = limitAlerts(usage: u, notified: ["5h": 1_008_000], now: now)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(marks, ["5h": 1_020_000])
    }

    func testDropBelowThresholdClearsMark() {
        let u = usage(five: UsageWindow(utilization: 30, resetUnix: 1_020_000))
        let (alerts, marks) = limitAlerts(usage: u, notified: ["5h": 1_008_000], now: now)
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertEqual(marks, [:])
    }

    func testNilResetsAtUsesZeroMark() {
        let u = usage(five: UsageWindow(utilization: 82, resetUnix: nil))
        let (alerts, marks) = limitAlerts(usage: u, notified: [:], now: now)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].body, "18% left")   // no reset tail
        XCTAssertEqual(marks, ["5h": 0])
        // Second pass: silent.
        let again = limitAlerts(usage: u, notified: marks, now: now)
        XCTAssertTrue(again.alerts.isEmpty)
    }

    func testSonnetWindowIgnored() {
        let u = usage(sonnet: UsageWindow(utilization: 99, resetUnix: 1_008_000))
        let (alerts, marks) = limitAlerts(usage: u, notified: [:], now: now)
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertTrue(marks.isEmpty)
    }

    func testBothWindowsAlertTogether() {
        let u = usage(five: UsageWindow(utilization: 80, resetUnix: 1_008_000),
                      seven: UsageWindow(utilization: 95, resetUnix: 1_600_000))
        let (alerts, marks) = limitAlerts(usage: u, notified: [:], now: now)
        XCTAssertEqual(alerts.map(\.windowKey), ["5h", "7d"])
        XCTAssertEqual(marks, ["5h": 1_008_000, "7d": 1_600_000])
    }

    func testMissingWindowKeepsMark() {
        // Network hiccup can drop a window from the payload; the current
        // cycle's dedup must survive it.
        let u = usage(seven: UsageWindow(utilization: 10, resetUnix: 1_600_000))
        let (alerts, marks) = limitAlerts(usage: u, notified: ["5h": 1_008_000], now: now)
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertEqual(marks, ["5h": 1_008_000])
    }

    func testAlertTextContent() {
        // reset = now + 2h13m exactly; remainingLabel ceils to "2h13m".
        let reset = Int64(1_000_000 + 2 * 3600 + 13 * 60)
        let u = usage(five: UsageWindow(utilization: 82.4, resetUnix: reset))
        let (alerts, _) = limitAlerts(usage: u, notified: [:], now: now)
        XCTAssertEqual(alerts[0].title, "Claude 5h limit at 82%")
        XCTAssertEqual(alerts[0].body, "18% left · resets in 2h13m")
    }

    func testOverHundredClampsRemainderToZero() {
        let u = usage(five: UsageWindow(utilization: 104, resetUnix: nil))
        let (alerts, _) = limitAlerts(usage: u, notified: [:], now: now)
        XCTAssertEqual(alerts[0].title, "Claude 5h limit at 104%")
        XCTAssertEqual(alerts[0].body, "0% left")
    }
}
```

- [ ] **Step 4: Прогнать — тесты падают**

Run: `swift test --filter LimitWatchTests`
Expected: FAIL — скелет возвращает пустые алерты (testCrossingEmitsAlertAndMark и остальные красные, кроме testSonnetWindowIgnored/testMissingWindowKeepsMark — они на скелете могут быть зелёными, это ок).

- [ ] **Step 5: Реализация** — заменить тело `limitAlerts` в `Sources/covey/LimitWatch.swift`:

```swift
func limitAlerts(usage: Usage, notified: [String: Int64], now: Date)
    -> (alerts: [LimitAlert], notified: [String: Int64]) {
    var marks = notified
    var alerts: [LimitAlert] = []
    // Sonnet's 7d window is deliberately absent: chip-only, no alerts.
    for (key, window) in [("5h", usage.fiveHour), ("7d", usage.sevenDay)] {
        guard let w = window else { continue }   // network gap: keep markers
        if w.utilization < limitAlertThreshold {
            marks[key] = nil
            continue
        }
        let mark = w.resetUnix ?? 0
        guard marks[key] != mark else { continue }
        marks[key] = mark
        let pct = Int(w.utilization.rounded())
        var body = "\(max(0, 100 - pct))% left"
        if let reset = w.resetUnix {
            body += " · resets in \(remainingLabel(resetUnix: reset, now: now))"
        }
        alerts.append(LimitAlert(windowKey: key,
                                 title: "Claude \(key) limit at \(pct)%",
                                 body: body))
    }
    return (alerts: alerts, notified: marks)
}
```

- [ ] **Step 6: Прогнать — тесты зелёные**

Run: `swift test --filter LimitWatchTests`
Expected: PASS, 10 tests, 0 failures

- [ ] **Step 7: Чекпойнт** — предложить пользователю коммит:

```
feat(covey): pure usage-limit alert detector
```

---

### Task 3: Notifier — обёртка UNUserNotificationCenter

**Files:**
- Create: `Sources/covey/Notifier.swift`

**Interfaces:**
- Consumes: `LimitAlert` (Task 2).
- Produces: `enum Notifier` со `static var available: Bool`, `static func requestPermission()`, `static func post(_ alert: LimitAlert)`. Юнитов нет (тонкий системный враппер, спека §2): вне бандла всё no-op, что и позволяет гонять `swift test`.

- [ ] **Step 1: Реализация** — `Sources/covey/Notifier.swift`:

```swift
import Foundation
import UserNotifications

/// System-notification facade. All the bundle quirks live here:
/// UNUserNotificationCenter traps outside an .app bundle — both in bare
/// `swift build` binaries and in the xctest host (which HAS a bundle
/// identifier, hence the bundleURL extension check).
enum Notifier {
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Fire-and-forget: a denied permission just means `post` goes nowhere.
    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ alert: LimitAlert) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        // No categories or custom actions: the default click activates
        // the app, which is all we need.
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
```

- [ ] **Step 2: Прогнать сборку и тесты**

Run: `swift build && swift test`
Expected: OK, 0 failures

- [ ] **Step 3: Чекпойнт** — предложить пользователю коммит:

```
feat(covey): system notification facade gated on app bundle
```

---

### Task 4: Wiring — tickUsage + permission на старте

**Files:**
- Modify: `Sources/covey/AppModel.swift` (метод `tickUsage()`, сейчас ~строка 867 — матчить по коду, не по номеру)
- Modify: `Sources/covey/App.swift` (`.task` блок создания модели, после `await m.start()`)
- Test: `Tests/CoveyAppTests/AppModelUsageTests.swift`

**Interfaces:**
- Consumes: `limitAlerts` (Task 2), `Notifier` (Task 3), `PersistedState.usageNotified` (Task 1), приватные `persisted`/`persist()` в AppModel.
- Produces: поведение — на тике с окном ≥ 80% постится уведомление и маркер уезжает в `~/.covey/state.json`.

- [ ] **Step 1: Падающий тест** — в класс `AppModelUsageTests` (`Tests/CoveyAppTests/AppModelUsageTests.swift`). Существующий хелпер `makeUsageModel` прячет путь state-файла, поэтому тест собирает модель сам, с явным `statePath`:

```swift
    @MainActor
    func testLimitCrossingPersistsMarker() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let statePath = "\(NSTemporaryDirectory())covey-limit-\(UInt32.random(in: 0..<UInt32.max)).json"
        let acc = Account(usage: Usage(
            fiveHour: UsageWindow(utilization: 82, resetUnix: 1_008_000),
            sevenDay: nil, sevenDaySonnet: nil))
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(
            client: client,
            makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
            store: StateStore(path: statePath, debounce: 0.05),
            fetchAccount: { acc },
            usageInterval: 0.05)
        await model.start()
        let persisted = await eventually {
            guard let data = FileManager.default.contents(atPath: statePath),
                  let st = try? JSONDecoder().decode(PersistedState.self, from: data)
            else { return false }
            return st.usageNotified == ["5h": 1_008_000]
        }
        XCTAssertTrue(persisted)
    }
```

- [ ] **Step 2: Прогнать — тест падает**

Run: `swift test --filter AppModelUsageTests.testLimitCrossingPersistsMarker`
Expected: FAIL — `usageNotified` в файл не пишется (eventually истекает, XCTAssertTrue(false))

- [ ] **Step 3: Реализация wiring** — в `Sources/covey/AppModel.swift` заменить `tickUsage()`:

```swift
    private func tickUsage() async {
        let acc = await fetchAccount()
        usage = acc.usage
        plan = acc.plan
        usageError = acc.usageError
        // Failed fetch (nil usage) must not touch alert markers: the
        // current window's dedup survives network gaps.
        guard let usage = acc.usage else { return }
        let old = persisted.usageNotified ?? [:]
        let (alerts, marks) = limitAlerts(usage: usage, notified: old, now: Date())
        for alert in alerts { Notifier.post(alert) }
        if marks != old {
            persisted.usageNotified = marks
            persist()
        }
    }
```

Примечание: `persist()` переписывает в `persisted` только UI-поля и не трогает `usageNotified` — присваивание перед вызовом безопасно.

- [ ] **Step 4: Прогнать — тест зелёный**

Run: `swift test --filter AppModelUsageTests`
Expected: PASS, 0 failures (в тестах `Notifier.available == false` — post no-op, трапа нет)

- [ ] **Step 5: Permission на старте** — в `Sources/covey/App.swift`, в `.task`-блоке после `await m.start()` и перед `model = m`:

```swift
                    await m.start()
                    Notifier.requestPermission()
                    model = m
```

- [ ] **Step 6: Полный прогон**

Run: `swift build && swift test`
Expected: OK, 0 failures

- [ ] **Step 7: Чекпойнт** — предложить пользователю коммит:

```
feat(covey): system notification when 5h/7d usage crosses 80%
```

---

### Task 5: Ручная проверка в бандле

**Files:** нет (только сборка и наблюдение).

- [ ] **Step 1: Собрать и поставить бандл**

Run: `make install`
Expected: `Installed /Applications/Covey.app`

- [ ] **Step 2: Проверить permission-диалог** — запустить Covey.app: при первом старте macOS спрашивает разрешение на уведомления. Разрешить.

- [ ] **Step 3: Проверить уведомление** — если реальная утилизация < 80%, временно (не коммитя) опустить `limitAlertThreshold` в `Sources/covey/LimitWatch.swift` до значения ниже текущего процента, пересобрать `make install`, дождаться тика (≤ 60с): приходит уведомление вида `Claude 5h limit at 41%` / `59% left · resets in 3h2m`. Клик активирует Covey. В течение минуты повтора нет (маркер записан).

- [ ] **Step 4: Проверить дедуп через рестарт** — перезапустить Covey.app: уведомление НЕ повторяется (маркер в `~/.covey/state.json`).

- [ ] **Step 5: Откатить временный порог** — вернуть `limitAlertThreshold = 80.0`, если менялся; `make install` финальной сборки. Сообщить пользователю, что слайс готов к финальному коммиту.
