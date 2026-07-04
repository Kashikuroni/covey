# Слайс 21 — полировка хрома (иконки агентов, countdown лимитов, минус кнопка темы) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Иконки Claude/OpenAI на карточках сессий вместо текста, обратный отсчёт до сброса лимитов в usage-чипе, удаление кнопки темы из TopBar.

**Architecture:** GUI-only слайс (таргет `covey`), демон и протокол не меняются. Новый файл `AgentIcon.swift` — классификатор агента + view (иконка Claude.app через NSWorkspace / векторный логотип OpenAI / текст-фолбэк). `UsageWindow` теряет `resetHHMM`; остаток считается из `resetUnix` чистой функцией `remainingLabel`, чип тикает через `TimelineView(.everyMinute)`.

**Tech Stack:** Swift 6.3 / SwiftPM, SwiftUI, AppKit (NSWorkspace), XCTest.

## Global Constraints

- Спека: `docs/superpowers/specs/2026-07-04-covey-chrome-polish-design.md`.
- Весь код и коммиты на английском.
- Полный прогон: `swift test` — 0 failures (перед каждым коммитом).
- Git-коммиты выполняет пользователь (агент выдаёт команды).
- SourceKit-диагностике при кросс-модульных правках не верить — верить `swift build`/`swift test`.

---

### Task 1: Убрать кнопку темы из TopBar

**Files:**
- Modify: `Sources/covey/Views/TopBar.swift:16-21`

**Interfaces:**
- Consumes: `model.setTheme` больше не вызывается из TopBar (остаётся `space a t` → `AppModel.apply(.toggleTheme)`).
- Produces: ничего нового.

- [ ] **Step 1: Удалить Button**

В `TopBar.swift` удалить целиком:

```swift
            Button {
                model.setTheme(model.themeRaw == "dark" ? "light" : "dark")
            } label: {
                Image(systemName: model.themeRaw == "dark" ? "sun.max" : "moon")
            }
            .buttonStyle(.borderless).help("Toggle theme")
```

`TimelineView` с часами остаётся сразу после `Spacer()`.

- [ ] **Step 2: Сборка и тесты**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: `0 failures` (view-код не тестируется, набор не меняется).

- [ ] **Step 3: Commit (user)**

```bash
git add Sources/covey/Views/TopBar.swift
git commit -m "feat(covey): drop theme toggle button from topbar"
```

---

### Task 2: Обратный отсчёт до сброса лимитов

**Files:**
- Modify: `Sources/covey/Usage.swift` (убрать `resetHHMM`)
- Modify: `Sources/covey/UsageService.swift` (убрать `fillResetTimes`)
- Modify: `Sources/covey/Views/UsageChip.swift` (`remainingLabel`, `windowLabel(now:)`, `TimelineView`)
- Test: `Tests/CoveyAppTests/UsageChipTests.swift`
- Modify: `Tests/CoveyAppTests/AppModelUsageTests.swift:23` (конструктор без `resetHHMM`)

**Interfaces:**
- Consumes: `UsageWindow.resetUnix: Int64?` (уже есть, из `resets_at`).
- Produces: `func remainingLabel(resetUnix: Int64, now: Date) -> String`; `func windowLabel(_ prefix: String, _ w: UsageWindow, now: Date) -> String`. `UsageWindow` теперь `{ utilization: Double, resetUnix: Int64? }`.

- [ ] **Step 1: Переписать UsageChipTests (failing)**

Заменить содержимое `Tests/CoveyAppTests/UsageChipTests.swift` на:

```swift
import XCTest
@testable import covey

final class UsageChipTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func label(afterSeconds secs: Int64) -> String {
        remainingLabel(resetUnix: 1_750_000_000 + secs, now: now)
    }

    func testRemainingLabelExpired() {
        XCTAssertEqual(label(afterSeconds: 0), "0m")
        XCTAssertEqual(label(afterSeconds: -3600), "0m")
    }

    func testRemainingLabelMinutes() {
        XCTAssertEqual(label(afterSeconds: 60), "1m")
        XCTAssertEqual(label(afterSeconds: 37 * 60), "37m")
        XCTAssertEqual(label(afterSeconds: 59 * 60), "59m")
    }

    func testRemainingLabelHours() {
        XCTAssertEqual(label(afterSeconds: 3600), "1h")
        XCTAssertEqual(label(afterSeconds: (2 * 60 + 13) * 60), "2h13m")
        XCTAssertEqual(label(afterSeconds: (23 * 60 + 59) * 60), "23h59m")
    }

    func testRemainingLabelDays() {
        XCTAssertEqual(label(afterSeconds: 24 * 3600), "1d")
        XCTAssertEqual(label(afterSeconds: (3 * 24 + 4) * 3600), "3d4h")
    }

    func testRemainingLabelCeilsPartialMinutes() {
        // 61s is "2 minutes to go" — never show less time than remains.
        XCTAssertEqual(label(afterSeconds: 61), "2m")
    }

    func testWindowLabelRoundsPercent() {
        let w = UsageWindow(utilization: 76.6, resetUnix: nil)
        XCTAssertEqual(windowLabel("5h", w, now: now), "5h 77%")
    }

    func testWindowLabelIncludesCountdownWhenResetKnown() {
        let w = UsageWindow(utilization: 40, resetUnix: 1_750_000_000 + (2 * 60 + 13) * 60)
        XCTAssertEqual(windowLabel("7d", w, now: now), "7d 40% · 2h13m")
    }
}
```

(`testIsClaudeAgent` уезжает в Task 3 → `AgentIconTests`; здесь его больше нет.)

- [ ] **Step 2: Прогнать — убедиться, что падает**

Run: `swift test --filter UsageChipTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'remainingLabel' in scope`, лишний аргумент `now` (ошибки компиляции таргета тестов).

- [ ] **Step 3: Реализация**

`Sources/covey/Usage.swift` — `UsageWindow` теряет поле:

```swift
public struct UsageWindow: Equatable {
    public var utilization: Double     // 0–100
    public var resetUnix: Int64?       // reset instant, from `resets_at`
}
```

Там же в `parseUsage` конструктор:

```swift
        return UsageWindow(utilization: util, resetUnix: resetUnix)
```

Комментарий над `parseUsage` («`resetHHMM` is NOT formatted here…») заменить на:

```swift
/// Parses the `/api/oauth/usage` body. Returns nil if unusable or all
/// windows are null.
```

`Sources/covey/UsageService.swift` — удалить `fillResetTimes` целиком и его вызов; ветка success становится:

```swift
        case .success(let body):
            if let usage = parseUsage(body) {
                acc.usage = usage
            } else {
                acc.usageError = "parse"
            }
```

`Sources/covey/Views/UsageChip.swift` — заменить `windowLabel` и тело чипа:

```swift
import SwiftUI

/// "2h13m" until the window resets; ceils so it never understates.
func remainingLabel(resetUnix: Int64, now: Date) -> String {
    let secs = resetUnix - Int64(now.timeIntervalSince1970)
    if secs <= 0 { return "0m" }
    let mins = (secs + 59) / 60
    if mins < 60 { return "\(mins)m" }
    let hours = mins / 60
    if hours < 24 {
        let m = mins % 60
        return m == 0 ? "\(hours)h" : "\(hours)h\(m)m"
    }
    let days = hours / 24
    let h = hours % 24
    return h == 0 ? "\(days)d" : "\(days)d\(h)h"
}

/// "5h 77%" or "7d 40% · 2h13m" (with time to reset when known).
func windowLabel(_ prefix: String, _ w: UsageWindow, now: Date) -> String {
    let pct = Int(w.utilization.rounded())
    if let reset = w.resetUnix { return "\(prefix) \(pct)% · \(remainingLabel(resetUnix: reset, now: now))" }
    return "\(prefix) \(pct)%"
}

/// Compact Claude usage chip: windows + plan badge, or an error code.
struct UsageChip: View {
    let usage: Usage?
    let plan: String?
    let error: String?

    var body: some View {
        if let usage {
            // Ticks every minute: countdowns must advance even when the
            // polled Usage snapshot is Equatable-equal (no re-render).
            TimelineView(.everyMinute) { ctx in
                HStack(spacing: 8) {
                    if let w = usage.fiveHour { pill(windowLabel("5h", w, now: ctx.date)) }
                    if let w = usage.sevenDay { pill(windowLabel("7d", w, now: ctx.date)) }
                    if let w = usage.sevenDaySonnet { pill(windowLabel("S 7d", w, now: ctx.date)) }
                    if let plan { pill(plan).foregroundStyle(.secondary) }
                }
                .font(.caption)
            }
        } else if let error {
            Text("usage: \(error)").font(.caption).foregroundStyle(.orange)
        } else {
            EmptyView()
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .glassEffect()
    }
}
```

ВНИМАНИЕ: `isClaudeAgent` в этом файле пока НЕ трогать (умрёт в Task 3).

`Tests/CoveyAppTests/AppModelUsageTests.swift:23` — конструктор:

```swift
        let acc = Account(usage: Usage(fiveHour: UsageWindow(utilization: 55, resetUnix: nil),
```

(остаток строки без изменений).

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter "UsageChipTests|UsageParseTests|AppModelUsageTests" 2>&1 | tail -3`
Expected: PASS, 0 failures.

Run: `swift test 2>&1 | tail -3`
Expected: полный набор, 0 failures.

- [ ] **Step 5: Commit (user)**

```bash
git add Sources/covey/Usage.swift Sources/covey/UsageService.swift Sources/covey/Views/UsageChip.swift Tests/CoveyAppTests/UsageChipTests.swift Tests/CoveyAppTests/AppModelUsageTests.swift
git commit -m "feat(covey): usage chip counts down to limit reset"
```

---

### Task 3: Иконки агентов на карточках

**Files:**
- Create: `Sources/covey/Views/AgentIcon.swift`
- Modify: `Sources/covey/Views/SessionListView.swift` (2 вхождения `Text(session.agent)`)
- Modify: `Sources/covey/Views/TerminalPaneView.swift:28` (`isClaudeAgent` → `agentKind`)
- Modify: `Sources/covey/Views/UsageChip.swift` (удалить `isClaudeAgent`)
- Test: `Tests/CoveyAppTests/AgentIconTests.swift` (новый)

**Interfaces:**
- Consumes: `Tokens` (поле `t3: Color`), `Session.agent: String`.
- Produces: `enum AgentKind { case claude, codex, other }`; `func agentKind(_ agent: String) -> AgentKind`; `func claudeIcon(at path: String) -> NSImage?`; `struct CodexLogo: Shape`; `struct AgentIcon: View { let agent: String; let tk: Tokens }`.

- [ ] **Step 1: Написать AgentIconTests (failing)**

Создать `Tests/CoveyAppTests/AgentIconTests.swift`:

```swift
import XCTest
@testable import covey

final class AgentIconTests: XCTestCase {
    func testAgentKindClassifiesByName() {
        XCTAssertEqual(agentKind("claude"), .claude)
        XCTAssertEqual(agentKind("claude-yolo"), .claude)
        XCTAssertEqual(agentKind("/usr/local/bin/Claude"), .claude)
        XCTAssertEqual(agentKind("codex"), .codex)
        XCTAssertEqual(agentKind("my-codex --full-auto"), .codex)
        XCTAssertEqual(agentKind("aider"), .other)
        XCTAssertEqual(agentKind("sh"), .other)
        XCTAssertEqual(agentKind(""), .other)
    }

    func testClaudeIconNilForMissingApp() {
        XCTAssertNil(claudeIcon(at: "/Applications/NoSuchApp12345.app"))
    }

    func testCodexLogoFillsUnitRect() {
        let bounds = CodexLogo().path(in: CGRect(x: 0, y: 0, width: 24, height: 24)).boundingRect
        // The blossom spans nearly the whole viewBox (simple-icons 24×24).
        XCTAssertGreaterThan(bounds.width, 20)
        XCTAssertGreaterThan(bounds.height, 20)
        XCTAssertGreaterThanOrEqual(bounds.minX, 0)
        XCTAssertGreaterThanOrEqual(bounds.minY, 0)
    }
}
```

- [ ] **Step 2: Прогнать — убедиться, что падает**

Run: `swift test --filter AgentIconTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'agentKind' in scope` (компиляция).

- [ ] **Step 3: Создать AgentIcon.swift**

Создать `Sources/covey/Views/AgentIcon.swift`. Path-код логотипа OpenAI сгенерирован из simple-icons `openai.svg` (viewBox 24×24, дуги приближены кубическими безье, макс. отклонение 0.0012 юнита) — вставить как есть:

```swift
import SwiftUI
import AppKit

enum AgentKind: Equatable { case claude, codex, other }

/// Classify an agent command string ("claude", "claude-yolo", "codex", …).
func agentKind(_ agent: String) -> AgentKind {
    let a = agent.lowercased()
    if a.contains("claude") { return .claude }
    if a.contains("codex") { return .codex }
    return .other
}

/// App icon at `path`, or nil when not installed (callers fall back to text).
func claudeIcon(at path: String) -> NSImage? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    return NSWorkspace.shared.icon(forFile: path)
}

/// Fetched once per launch; the icon file never changes mid-session.
let claudeAppIcon: NSImage? = claudeIcon(at: "/Applications/Claude.app")

/// OpenAI blossom (simple-icons openai.svg; arcs pre-converted to cubics).
struct CodexLogo: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: 0.9284 * w, y: 0.4092 * h))
        p.addCurve(to: CGPoint(x: 0.9397 * w, y: 0.3575 * h), control1: CGPoint(x: 0.9340 * w, y: 0.3924 * h), control2: CGPoint(x: 0.9378 * w, y: 0.3751 * h))
        p.addCurve(to: CGPoint(x: 0.9398 * w, y: 0.3046 * h), control1: CGPoint(x: 0.9416 * w, y: 0.3399 * h), control2: CGPoint(x: 0.9416 * w, y: 0.3222 * h))
        p.addCurve(to: CGPoint(x: 0.9287 * w, y: 0.2528 * h), control1: CGPoint(x: 0.9379 * w, y: 0.2870 * h), control2: CGPoint(x: 0.9342 * w, y: 0.2696 * h))
        p.addCurve(to: CGPoint(x: 0.9069 * w, y: 0.2046 * h), control1: CGPoint(x: 0.9232 * w, y: 0.2360 * h), control2: CGPoint(x: 0.9159 * w, y: 0.2198 * h))
        p.addCurve(to: CGPoint(x: 0.8573 * w, y: 0.1431 * h), control1: CGPoint(x: 0.8937 * w, y: 0.1817 * h), control2: CGPoint(x: 0.8769 * w, y: 0.1608 * h))
        p.addCurve(to: CGPoint(x: 0.7910 * w, y: 0.1000 * h), control1: CGPoint(x: 0.8376 * w, y: 0.1253 * h), control2: CGPoint(x: 0.8152 * w, y: 0.1107 * h))
        p.addCurve(to: CGPoint(x: 0.7146 * w, y: 0.0795 * h), control1: CGPoint(x: 0.7668 * w, y: 0.0892 * h), control2: CGPoint(x: 0.7409 * w, y: 0.0823 * h))
        p.addCurve(to: CGPoint(x: 0.6357 * w, y: 0.0838 * h), control1: CGPoint(x: 0.6883 * w, y: 0.0768 * h), control2: CGPoint(x: 0.6616 * w, y: 0.0782 * h))
        p.addCurve(to: CGPoint(x: 0.5261 * w, y: 0.0124 * h), control1: CGPoint(x: 0.6062 * w, y: 0.0510 * h), control2: CGPoint(x: 0.5680 * w, y: 0.0261 * h))
        p.addCurve(to: CGPoint(x: 0.3955 * w, y: 0.0055 * h), control1: CGPoint(x: 0.4842 * w, y: -0.0012 * h), control2: CGPoint(x: 0.4386 * w, y: -0.0037 * h))
        p.addCurve(to: CGPoint(x: 0.2789 * w, y: 0.0647 * h), control1: CGPoint(x: 0.3524 * w, y: 0.0146 * h), control2: CGPoint(x: 0.3117 * w, y: 0.0352 * h))
        p.addCurve(to: CGPoint(x: 0.2075 * w, y: 0.1742 * h), control1: CGPoint(x: 0.2461 * w, y: 0.0941 * h), control2: CGPoint(x: 0.2212 * w, y: 0.1323 * h))
        p.addCurve(to: CGPoint(x: 0.1571 * w, y: 0.1903 * h), control1: CGPoint(x: 0.1902 * w, y: 0.1778 * h), control2: CGPoint(x: 0.1733 * w, y: 0.1832 * h))
        p.addCurve(to: CGPoint(x: 0.1112 * w, y: 0.2167 * h), control1: CGPoint(x: 0.1409 * w, y: 0.1974 * h), control2: CGPoint(x: 0.1255 * w, y: 0.2063 * h))
        p.addCurve(to: CGPoint(x: 0.0719 * w, y: 0.2521 * h), control1: CGPoint(x: 0.0969 * w, y: 0.2271 * h), control2: CGPoint(x: 0.0837 * w, y: 0.2390 * h))
        p.addCurve(to: CGPoint(x: 0.0410 * w, y: 0.2951 * h), control1: CGPoint(x: 0.0601 * w, y: 0.2653 * h), control2: CGPoint(x: 0.0497 * w, y: 0.2797 * h))
        p.addCurve(to: CGPoint(x: 0.0124 * w, y: 0.3689 * h), control1: CGPoint(x: 0.0276 * w, y: 0.3180 * h), control2: CGPoint(x: 0.0180 * w, y: 0.3430 * h))
        p.addCurve(to: CGPoint(x: 0.0082 * w, y: 0.4480 * h), control1: CGPoint(x: 0.0068 * w, y: 0.3948 * h), control2: CGPoint(x: 0.0054 * w, y: 0.4216 * h))
        p.addCurve(to: CGPoint(x: 0.0287 * w, y: 0.5244 * h), control1: CGPoint(x: 0.0109 * w, y: 0.4743 * h), control2: CGPoint(x: 0.0179 * w, y: 0.5002 * h))
        p.addCurve(to: CGPoint(x: 0.0719 * w, y: 0.5908 * h), control1: CGPoint(x: 0.0395 * w, y: 0.5486 * h), control2: CGPoint(x: 0.0541 * w, y: 0.5711 * h))
        p.addCurve(to: CGPoint(x: 0.0606 * w, y: 0.6425 * h), control1: CGPoint(x: 0.0663 * w, y: 0.6075 * h), control2: CGPoint(x: 0.0625 * w, y: 0.6249 * h))
        p.addCurve(to: CGPoint(x: 0.0604 * w, y: 0.6954 * h), control1: CGPoint(x: 0.0587 * w, y: 0.6600 * h), control2: CGPoint(x: 0.0586 * w, y: 0.6778 * h))
        p.addCurve(to: CGPoint(x: 0.0715 * w, y: 0.7471 * h), control1: CGPoint(x: 0.0623 * w, y: 0.7129 * h), control2: CGPoint(x: 0.0660 * w, y: 0.7303 * h))
        p.addCurve(to: CGPoint(x: 0.0932 * w, y: 0.7954 * h), control1: CGPoint(x: 0.0770 * w, y: 0.7639 * h), control2: CGPoint(x: 0.0843 * w, y: 0.7801 * h))
        p.addCurve(to: CGPoint(x: 0.1429 * w, y: 0.8569 * h), control1: CGPoint(x: 0.1064 * w, y: 0.8183 * h), control2: CGPoint(x: 0.1232 * w, y: 0.8392 * h))
        p.addCurve(to: CGPoint(x: 0.2092 * w, y: 0.9000 * h), control1: CGPoint(x: 0.1626 * w, y: 0.8747 * h), control2: CGPoint(x: 0.1850 * w, y: 0.8893 * h))
        p.addCurve(to: CGPoint(x: 0.2856 * w, y: 0.9205 * h), control1: CGPoint(x: 0.2334 * w, y: 0.9108 * h), control2: CGPoint(x: 0.2593 * w, y: 0.9177 * h))
        p.addCurve(to: CGPoint(x: 0.3646 * w, y: 0.9162 * h), control1: CGPoint(x: 0.3120 * w, y: 0.9232 * h), control2: CGPoint(x: 0.3387 * w, y: 0.9218 * h))
        p.addCurve(to: CGPoint(x: 0.4038 * w, y: 0.9518 * h), control1: CGPoint(x: 0.3764 * w, y: 0.9294 * h), control2: CGPoint(x: 0.3895 * w, y: 0.9414 * h))
        p.addCurve(to: CGPoint(x: 0.4495 * w, y: 0.9784 * h), control1: CGPoint(x: 0.4180 * w, y: 0.9623 * h), control2: CGPoint(x: 0.4334 * w, y: 0.9712 * h))
        p.addCurve(to: CGPoint(x: 0.4999 * w, y: 0.9947 * h), control1: CGPoint(x: 0.4657 * w, y: 0.9856 * h), control2: CGPoint(x: 0.4826 * w, y: 0.9911 * h))
        p.addCurve(to: CGPoint(x: 0.5525 * w, y: 1.0000 * h), control1: CGPoint(x: 0.5171 * w, y: 0.9983 * h), control2: CGPoint(x: 0.5348 * w, y: 1.0001 * h))
        p.addCurve(to: CGPoint(x: 0.6308 * w, y: 0.9876 * h), control1: CGPoint(x: 0.5790 * w, y: 1.0000 * h), control2: CGPoint(x: 0.6055 * w, y: 0.9958 * h))
        p.addCurve(to: CGPoint(x: 0.7013 * w, y: 0.9516 * h), control1: CGPoint(x: 0.6560 * w, y: 0.9794 * h), control2: CGPoint(x: 0.6799 * w, y: 0.9672 * h))
        p.addCurve(to: CGPoint(x: 0.7572 * w, y: 0.8955 * h), control1: CGPoint(x: 0.7228 * w, y: 0.9360 * h), control2: CGPoint(x: 0.7417 * w, y: 0.9170 * h))
        p.addCurve(to: CGPoint(x: 0.7930 * w, y: 0.8248 * h), control1: CGPoint(x: 0.7728 * w, y: 0.8740 * h), control2: CGPoint(x: 0.7849 * w, y: 0.8500 * h))
        p.addCurve(to: CGPoint(x: 0.8434 * w, y: 0.8087 * h), control1: CGPoint(x: 0.8103 * w, y: 0.8212 * h), control2: CGPoint(x: 0.8272 * w, y: 0.8158 * h))
        p.addCurve(to: CGPoint(x: 0.8893 * w, y: 0.7823 * h), control1: CGPoint(x: 0.8596 * w, y: 0.8015 * h), control2: CGPoint(x: 0.8750 * w, y: 0.7927 * h))
        p.addCurve(to: CGPoint(x: 0.9286 * w, y: 0.7469 * h), control1: CGPoint(x: 0.9036 * w, y: 0.7719 * h), control2: CGPoint(x: 0.9168 * w, y: 0.7600 * h))
        p.addCurve(to: CGPoint(x: 0.9596 * w, y: 0.7039 * h), control1: CGPoint(x: 0.9404 * w, y: 0.7337 * h), control2: CGPoint(x: 0.9508 * w, y: 0.7193 * h))
        p.addCurve(to: CGPoint(x: 0.9877 * w, y: 0.6303 * h), control1: CGPoint(x: 0.9727 * w, y: 0.6810 * h), control2: CGPoint(x: 0.9823 * w, y: 0.6561 * h))
        p.addCurve(to: CGPoint(x: 0.9918 * w, y: 0.5515 * h), control1: CGPoint(x: 0.9932 * w, y: 0.6044 * h), control2: CGPoint(x: 0.9946 * w, y: 0.5778 * h))
        p.addCurve(to: CGPoint(x: 0.9714 * w, y: 0.4754 * h), control1: CGPoint(x: 0.9890 * w, y: 0.5253 * h), control2: CGPoint(x: 0.9821 * w, y: 0.4995 * h))
        p.addCurve(to: CGPoint(x: 0.9284 * w, y: 0.4092 * h), control1: CGPoint(x: 0.9606 * w, y: 0.4512 * h), control2: CGPoint(x: 0.9461 * w, y: 0.4288 * h))
        p.addLine(to: CGPoint(x: 0.9284 * w, y: 0.4092 * h))
        p.move(to: CGPoint(x: 0.5525 * w, y: 0.9346 * h))
        p.addCurve(to: CGPoint(x: 0.5201 * w, y: 0.9318 * h), control1: CGPoint(x: 0.5417 * w, y: 0.9346 * h), control2: CGPoint(x: 0.5308 * w, y: 0.9336 * h))
        p.addCurve(to: CGPoint(x: 0.4888 * w, y: 0.9234 * h), control1: CGPoint(x: 0.5095 * w, y: 0.9299 * h), control2: CGPoint(x: 0.4989 * w, y: 0.9271 * h))
        p.addCurve(to: CGPoint(x: 0.4593 * w, y: 0.9098 * h), control1: CGPoint(x: 0.4786 * w, y: 0.9197 * h), control2: CGPoint(x: 0.4687 * w, y: 0.9152 * h))
        p.addCurve(to: CGPoint(x: 0.4326 * w, y: 0.8912 * h), control1: CGPoint(x: 0.4499 * w, y: 0.9044 * h), control2: CGPoint(x: 0.4410 * w, y: 0.8981 * h))
        p.addLine(to: CGPoint(x: 0.4386 * w, y: 0.8878 * h))
        p.addLine(to: CGPoint(x: 0.6377 * w, y: 0.7729 * h))
        p.addCurve(to: CGPoint(x: 0.6444 * w, y: 0.7677 * h), control1: CGPoint(x: 0.6401 * w, y: 0.7715 * h), control2: CGPoint(x: 0.6424 * w, y: 0.7697 * h))
        p.addCurve(to: CGPoint(x: 0.6496 * w, y: 0.7609 * h), control1: CGPoint(x: 0.6464 * w, y: 0.7656 * h), control2: CGPoint(x: 0.6482 * w, y: 0.7634 * h))
        p.addCurve(to: CGPoint(x: 0.6529 * w, y: 0.7530 * h), control1: CGPoint(x: 0.6510 * w, y: 0.7584 * h), control2: CGPoint(x: 0.6521 * w, y: 0.7557 * h))
        p.addCurve(to: CGPoint(x: 0.6540 * w, y: 0.7445 * h), control1: CGPoint(x: 0.6536 * w, y: 0.7502 * h), control2: CGPoint(x: 0.6540 * w, y: 0.7474 * h))
        p.addLine(to: CGPoint(x: 0.6540 * w, y: 0.4638 * h))
        p.addLine(to: CGPoint(x: 0.7382 * w, y: 0.5125 * h))
        p.addCurve(to: CGPoint(x: 0.7388 * w, y: 0.5129 * h), control1: CGPoint(x: 0.7384 * w, y: 0.5126 * h), control2: CGPoint(x: 0.7386 * w, y: 0.5127 * h))
        p.addCurve(to: CGPoint(x: 0.7392 * w, y: 0.5134 * h), control1: CGPoint(x: 0.7389 * w, y: 0.5130 * h), control2: CGPoint(x: 0.7391 * w, y: 0.5132 * h))
        p.addCurve(to: CGPoint(x: 0.7396 * w, y: 0.5140 * h), control1: CGPoint(x: 0.7394 * w, y: 0.5136 * h), control2: CGPoint(x: 0.7395 * w, y: 0.5138 * h))
        p.addCurve(to: CGPoint(x: 0.7398 * w, y: 0.5147 * h), control1: CGPoint(x: 0.7397 * w, y: 0.5142 * h), control2: CGPoint(x: 0.7397 * w, y: 0.5144 * h))
        p.addLine(to: CGPoint(x: 0.7398 * w, y: 0.7473 * h))
        p.addCurve(to: CGPoint(x: 0.7254 * w, y: 0.8189 * h), control1: CGPoint(x: 0.7397 * w, y: 0.7718 * h), control2: CGPoint(x: 0.7348 * w, y: 0.7963 * h))
        p.addCurve(to: CGPoint(x: 0.6848 * w, y: 0.8796 * h), control1: CGPoint(x: 0.7160 * w, y: 0.8415 * h), control2: CGPoint(x: 0.7021 * w, y: 0.8623 * h))
        p.addCurve(to: CGPoint(x: 0.6241 * w, y: 0.9202 * h), control1: CGPoint(x: 0.6675 * w, y: 0.8969 * h), control2: CGPoint(x: 0.6467 * w, y: 0.9108 * h))
        p.addCurve(to: CGPoint(x: 0.5525 * w, y: 0.9346 * h), control1: CGPoint(x: 0.6015 * w, y: 0.9296 * h), control2: CGPoint(x: 0.5770 * w, y: 0.9345 * h))
        p.addLine(to: CGPoint(x: 0.5525 * w, y: 0.9346 * h))
        p.move(to: CGPoint(x: 0.1500 * w, y: 0.7627 * h))
        p.addCurve(to: CGPoint(x: 0.1362 * w, y: 0.7332 * h), control1: CGPoint(x: 0.1445 * w, y: 0.7533 * h), control2: CGPoint(x: 0.1399 * w, y: 0.7434 * h))
        p.addCurve(to: CGPoint(x: 0.1277 * w, y: 0.7018 * h), control1: CGPoint(x: 0.1325 * w, y: 0.7230 * h), control2: CGPoint(x: 0.1296 * w, y: 0.7125 * h))
        p.addCurve(to: CGPoint(x: 0.1249 * w, y: 0.6695 * h), control1: CGPoint(x: 0.1259 * w, y: 0.6912 * h), control2: CGPoint(x: 0.1249 * w, y: 0.6803 * h))
        p.addCurve(to: CGPoint(x: 0.1277 * w, y: 0.6371 * h), control1: CGPoint(x: 0.1249 * w, y: 0.6586 * h), control2: CGPoint(x: 0.1258 * w, y: 0.6478 * h))
        p.addLine(to: CGPoint(x: 0.1336 * w, y: 0.6406 * h))
        p.addLine(to: CGPoint(x: 0.3329 * w, y: 0.7556 * h))
        p.addCurve(to: CGPoint(x: 0.3407 * w, y: 0.7589 * h), control1: CGPoint(x: 0.3354 * w, y: 0.7570 * h), control2: CGPoint(x: 0.3380 * w, y: 0.7581 * h))
        p.addCurve(to: CGPoint(x: 0.3492 * w, y: 0.7600 * h), control1: CGPoint(x: 0.3435 * w, y: 0.7596 * h), control2: CGPoint(x: 0.3463 * w, y: 0.7600 * h))
        p.addCurve(to: CGPoint(x: 0.3576 * w, y: 0.7589 * h), control1: CGPoint(x: 0.3520 * w, y: 0.7600 * h), control2: CGPoint(x: 0.3548 * w, y: 0.7596 * h))
        p.addCurve(to: CGPoint(x: 0.3654 * w, y: 0.7556 * h), control1: CGPoint(x: 0.3603 * w, y: 0.7581 * h), control2: CGPoint(x: 0.3630 * w, y: 0.7570 * h))
        p.addLine(to: CGPoint(x: 0.6089 * w, y: 0.6152 * h))
        p.addLine(to: CGPoint(x: 0.6089 * w, y: 0.7124 * h))
        p.addCurve(to: CGPoint(x: 0.6088 * w, y: 0.7131 * h), control1: CGPoint(x: 0.6089 * w, y: 0.7126 * h), control2: CGPoint(x: 0.6088 * w, y: 0.7129 * h))
        p.addCurve(to: CGPoint(x: 0.6085 * w, y: 0.7138 * h), control1: CGPoint(x: 0.6087 * w, y: 0.7134 * h), control2: CGPoint(x: 0.6086 * w, y: 0.7136 * h))
        p.addCurve(to: CGPoint(x: 0.6080 * w, y: 0.7144 * h), control1: CGPoint(x: 0.6084 * w, y: 0.7141 * h), control2: CGPoint(x: 0.6082 * w, y: 0.7143 * h))
        p.addCurve(to: CGPoint(x: 0.6075 * w, y: 0.7150 * h), control1: CGPoint(x: 0.6079 * w, y: 0.7146 * h), control2: CGPoint(x: 0.6077 * w, y: 0.7148 * h))
        p.addLine(to: CGPoint(x: 0.4058 * w, y: 0.8313 * h))
        p.addCurve(to: CGPoint(x: 0.3366 * w, y: 0.8547 * h), control1: CGPoint(x: 0.3846 * w, y: 0.8435 * h), control2: CGPoint(x: 0.3609 * w, y: 0.8515 * h))
        p.addCurve(to: CGPoint(x: 0.2637 * w, y: 0.8499 * h), control1: CGPoint(x: 0.3123 * w, y: 0.8579 * h), control2: CGPoint(x: 0.2874 * w, y: 0.8562 * h))
        p.addCurve(to: CGPoint(x: 0.1982 * w, y: 0.8176 * h), control1: CGPoint(x: 0.2400 * w, y: 0.8435 * h), control2: CGPoint(x: 0.2176 * w, y: 0.8325 * h))
        p.addCurve(to: CGPoint(x: 0.1500 * w, y: 0.7627 * h), control1: CGPoint(x: 0.1787 * w, y: 0.8027 * h), control2: CGPoint(x: 0.1622 * w, y: 0.7839 * h))
        p.addLine(to: CGPoint(x: 0.1500 * w, y: 0.7627 * h))
        p.move(to: CGPoint(x: 0.0975 * w, y: 0.3290 * h))
        p.addCurve(to: CGPoint(x: 0.1163 * w, y: 0.3022 * h), control1: CGPoint(x: 0.1030 * w, y: 0.3195 * h), control2: CGPoint(x: 0.1093 * w, y: 0.3106 * h))
        p.addCurve(to: CGPoint(x: 0.1395 * w, y: 0.2792 * h), control1: CGPoint(x: 0.1234 * w, y: 0.2939 * h), control2: CGPoint(x: 0.1312 * w, y: 0.2861 * h))
        p.addCurve(to: CGPoint(x: 0.1664 * w, y: 0.2605 * h), control1: CGPoint(x: 0.1479 * w, y: 0.2722 * h), control2: CGPoint(x: 0.1569 * w, y: 0.2659 * h))
        p.addCurve(to: CGPoint(x: 0.1961 * w, y: 0.2468 * h), control1: CGPoint(x: 0.1759 * w, y: 0.2551 * h), control2: CGPoint(x: 0.1858 * w, y: 0.2505 * h))
        p.addLine(to: CGPoint(x: 0.1961 * w, y: 0.4833 * h))
        p.addCurve(to: CGPoint(x: 0.1971 * w, y: 0.4918 * h), control1: CGPoint(x: 0.1961 * w, y: 0.4862 * h), control2: CGPoint(x: 0.1964 * w, y: 0.4890 * h))
        p.addCurve(to: CGPoint(x: 0.2003 * w, y: 0.4996 * h), control1: CGPoint(x: 0.1978 * w, y: 0.4945 * h), control2: CGPoint(x: 0.1989 * w, y: 0.4972 * h))
        p.addCurve(to: CGPoint(x: 0.2055 * w, y: 0.5064 * h), control1: CGPoint(x: 0.2017 * w, y: 0.5021 * h), control2: CGPoint(x: 0.2035 * w, y: 0.5044 * h))
        p.addCurve(to: CGPoint(x: 0.2123 * w, y: 0.5115 * h), control1: CGPoint(x: 0.2075 * w, y: 0.5084 * h), control2: CGPoint(x: 0.2098 * w, y: 0.5101 * h))
        p.addLine(to: CGPoint(x: 0.4545 * w, y: 0.6513 * h))
        p.addLine(to: CGPoint(x: 0.3704 * w, y: 0.7000 * h))
        p.addCurve(to: CGPoint(x: 0.3696 * w, y: 0.7002 * h), control1: CGPoint(x: 0.3701 * w, y: 0.7001 * h), control2: CGPoint(x: 0.3699 * w, y: 0.7002 * h))
        p.addCurve(to: CGPoint(x: 0.3689 * w, y: 0.7003 * h), control1: CGPoint(x: 0.3694 * w, y: 0.7003 * h), control2: CGPoint(x: 0.3691 * w, y: 0.7003 * h))
        p.addCurve(to: CGPoint(x: 0.3681 * w, y: 0.7002 * h), control1: CGPoint(x: 0.3686 * w, y: 0.7003 * h), control2: CGPoint(x: 0.3684 * w, y: 0.7003 * h))
        p.addCurve(to: CGPoint(x: 0.3674 * w, y: 0.7000 * h), control1: CGPoint(x: 0.3679 * w, y: 0.7002 * h), control2: CGPoint(x: 0.3676 * w, y: 0.7001 * h))
        p.addLine(to: CGPoint(x: 0.1661 * w, y: 0.5839 * h))
        p.addCurve(to: CGPoint(x: 0.1113 * w, y: 0.5356 * h), control1: CGPoint(x: 0.1449 * w, y: 0.5716 * h), control2: CGPoint(x: 0.1262 * w, y: 0.5551 * h))
        p.addCurve(to: CGPoint(x: 0.0790 * w, y: 0.4701 * h), control1: CGPoint(x: 0.0964 * w, y: 0.5162 * h), control2: CGPoint(x: 0.0853 * w, y: 0.4938 * h))
        p.addCurve(to: CGPoint(x: 0.0742 * w, y: 0.3972 * h), control1: CGPoint(x: 0.0726 * w, y: 0.4464 * h), control2: CGPoint(x: 0.0710 * w, y: 0.4215 * h))
        p.addCurve(to: CGPoint(x: 0.0975 * w, y: 0.3280 * h), control1: CGPoint(x: 0.0773 * w, y: 0.3729 * h), control2: CGPoint(x: 0.0853 * w, y: 0.3492 * h))
        p.addLine(to: CGPoint(x: 0.0975 * w, y: 0.3290 * h))
        p.move(to: CGPoint(x: 0.7890 * w, y: 0.4896 * h))
        p.addLine(to: CGPoint(x: 0.5460 * w, y: 0.3485 * h))
        p.addLine(to: CGPoint(x: 0.6300 * w, y: 0.3000 * h))
        p.addCurve(to: CGPoint(x: 0.6307 * w, y: 0.2997 * h), control1: CGPoint(x: 0.6302 * w, y: 0.2999 * h), control2: CGPoint(x: 0.6304 * w, y: 0.2998 * h))
        p.addCurve(to: CGPoint(x: 0.6314 * w, y: 0.2996 * h), control1: CGPoint(x: 0.6309 * w, y: 0.2997 * h), control2: CGPoint(x: 0.6312 * w, y: 0.2996 * h))
        p.addCurve(to: CGPoint(x: 0.6322 * w, y: 0.2997 * h), control1: CGPoint(x: 0.6317 * w, y: 0.2996 * h), control2: CGPoint(x: 0.6320 * w, y: 0.2997 * h))
        p.addCurve(to: CGPoint(x: 0.6329 * w, y: 0.3000 * h), control1: CGPoint(x: 0.6325 * w, y: 0.2998 * h), control2: CGPoint(x: 0.6327 * w, y: 0.2999 * h))
        p.addLine(to: CGPoint(x: 0.8342 * w, y: 0.4163 * h))
        p.addCurve(to: CGPoint(x: 0.9065 * w, y: 0.4917 * h), control1: CGPoint(x: 0.8648 * w, y: 0.4339 * h), control2: CGPoint(x: 0.8902 * w, y: 0.4604 * h))
        p.addCurve(to: CGPoint(x: 0.9272 * w, y: 0.5941 * h), control1: CGPoint(x: 0.9229 * w, y: 0.5230 * h), control2: CGPoint(x: 0.9301 * w, y: 0.5589 * h))
        p.addCurve(to: CGPoint(x: 0.8898 * w, y: 0.6916 * h), control1: CGPoint(x: 0.9243 * w, y: 0.6293 * h), control2: CGPoint(x: 0.9111 * w, y: 0.6635 * h))
        p.addCurve(to: CGPoint(x: 0.8060 * w, y: 0.7540 * h), control1: CGPoint(x: 0.8685 * w, y: 0.7198 * h), control2: CGPoint(x: 0.8391 * w, y: 0.7417 * h))
        p.addLine(to: CGPoint(x: 0.8060 * w, y: 0.5174 * h))
        p.addCurve(to: CGPoint(x: 0.8046 * w, y: 0.5090 * h), control1: CGPoint(x: 0.8059 * w, y: 0.5146 * h), control2: CGPoint(x: 0.8055 * w, y: 0.5118 * h))
        p.addCurve(to: CGPoint(x: 0.8012 * w, y: 0.5013 * h), control1: CGPoint(x: 0.8038 * w, y: 0.5063 * h), control2: CGPoint(x: 0.8027 * w, y: 0.5037 * h))
        p.addCurve(to: CGPoint(x: 0.7959 * w, y: 0.4947 * h), control1: CGPoint(x: 0.7997 * w, y: 0.4989 * h), control2: CGPoint(x: 0.7979 * w, y: 0.4966 * h))
        p.addCurve(to: CGPoint(x: 0.7890 * w, y: 0.4896 * h), control1: CGPoint(x: 0.7938 * w, y: 0.4927 * h), control2: CGPoint(x: 0.7915 * w, y: 0.4910 * h))
        p.addLine(to: CGPoint(x: 0.7890 * w, y: 0.4896 * h))
        p.move(to: CGPoint(x: 0.8728 * w, y: 0.3637 * h))
        p.addLine(to: CGPoint(x: 0.8669 * w, y: 0.3601 * h))
        p.addLine(to: CGPoint(x: 0.6680 * w, y: 0.2442 * h))
        p.addCurve(to: CGPoint(x: 0.6601 * w, y: 0.2409 * h), control1: CGPoint(x: 0.6655 * w, y: 0.2428 * h), control2: CGPoint(x: 0.6629 * w, y: 0.2417 * h))
        p.addCurve(to: CGPoint(x: 0.6516 * w, y: 0.2398 * h), control1: CGPoint(x: 0.6574 * w, y: 0.2402 * h), control2: CGPoint(x: 0.6545 * w, y: 0.2398 * h))
        p.addCurve(to: CGPoint(x: 0.6432 * w, y: 0.2409 * h), control1: CGPoint(x: 0.6488 * w, y: 0.2398 * h), control2: CGPoint(x: 0.6459 * w, y: 0.2402 * h))
        p.addCurve(to: CGPoint(x: 0.6353 * w, y: 0.2442 * h), control1: CGPoint(x: 0.6404 * w, y: 0.2417 * h), control2: CGPoint(x: 0.6378 * w, y: 0.2428 * h))
        p.addLine(to: CGPoint(x: 0.3920 * w, y: 0.3846 * h))
        p.addLine(to: CGPoint(x: 0.3920 * w, y: 0.2874 * h))
        p.addCurve(to: CGPoint(x: 0.3921 * w, y: 0.2867 * h), control1: CGPoint(x: 0.3920 * w, y: 0.2871 * h), control2: CGPoint(x: 0.3920 * w, y: 0.2869 * h))
        p.addCurve(to: CGPoint(x: 0.3923 * w, y: 0.2859 * h), control1: CGPoint(x: 0.3921 * w, y: 0.2864 * h), control2: CGPoint(x: 0.3922 * w, y: 0.2862 * h))
        p.addCurve(to: CGPoint(x: 0.3927 * w, y: 0.2853 * h), control1: CGPoint(x: 0.3924 * w, y: 0.2857 * h), control2: CGPoint(x: 0.3925 * w, y: 0.2855 * h))
        p.addCurve(to: CGPoint(x: 0.3932 * w, y: 0.2848 * h), control1: CGPoint(x: 0.3928 * w, y: 0.2851 * h), control2: CGPoint(x: 0.3930 * w, y: 0.2850 * h))
        p.addLine(to: CGPoint(x: 0.5945 * w, y: 0.1687 * h))
        p.addCurve(to: CGPoint(x: 0.6962 * w, y: 0.1439 * h), control1: CGPoint(x: 0.6251 * w, y: 0.1511 * h), control2: CGPoint(x: 0.6608 * w, y: 0.1423 * h))
        p.addCurve(to: CGPoint(x: 0.7953 * w, y: 0.1774 * h), control1: CGPoint(x: 0.7315 * w, y: 0.1454 * h), control2: CGPoint(x: 0.7663 * w, y: 0.1572 * h))
        p.addCurve(to: CGPoint(x: 0.8610 * w, y: 0.2589 * h), control1: CGPoint(x: 0.8243 * w, y: 0.1976 * h), control2: CGPoint(x: 0.8474 * w, y: 0.2263 * h))
        p.addCurve(to: CGPoint(x: 0.8728 * w, y: 0.3629 * h), control1: CGPoint(x: 0.8747 * w, y: 0.2915 * h), control2: CGPoint(x: 0.8788 * w, y: 0.3280 * h))
        p.addLine(to: CGPoint(x: 0.8728 * w, y: 0.3637 * h))
        p.move(to: CGPoint(x: 0.3461 * w, y: 0.5360 * h))
        p.addLine(to: CGPoint(x: 0.2619 * w, y: 0.4875 * h))
        p.addCurve(to: CGPoint(x: 0.2614 * w, y: 0.4870 * h), control1: CGPoint(x: 0.2617 * w, y: 0.4873 * h), control2: CGPoint(x: 0.2615 * w, y: 0.4872 * h))
        p.addCurve(to: CGPoint(x: 0.2609 * w, y: 0.4865 * h), control1: CGPoint(x: 0.2612 * w, y: 0.4869 * h), control2: CGPoint(x: 0.2610 * w, y: 0.4867 * h))
        p.addCurve(to: CGPoint(x: 0.2605 * w, y: 0.4858 * h), control1: CGPoint(x: 0.2607 * w, y: 0.4863 * h), control2: CGPoint(x: 0.2606 * w, y: 0.4860 * h))
        p.addCurve(to: CGPoint(x: 0.2604 * w, y: 0.4851 * h), control1: CGPoint(x: 0.2605 * w, y: 0.4856 * h), control2: CGPoint(x: 0.2604 * w, y: 0.4853 * h))
        p.addLine(to: CGPoint(x: 0.2604 * w, y: 0.2531 * h))
        p.addCurve(to: CGPoint(x: 0.2897 * w, y: 0.1526 * h), control1: CGPoint(x: 0.2604 * w, y: 0.2177 * h), control2: CGPoint(x: 0.2707 * w, y: 0.1825 * h))
        p.addCurve(to: CGPoint(x: 0.3683 * w, y: 0.0836 * h), control1: CGPoint(x: 0.3087 * w, y: 0.1228 * h), control2: CGPoint(x: 0.3363 * w, y: 0.0986 * h))
        p.addCurve(to: CGPoint(x: 0.4717 * w, y: 0.0674 * h), control1: CGPoint(x: 0.4003 * w, y: 0.0686 * h), control2: CGPoint(x: 0.4367 * w, y: 0.0629 * h))
        p.addCurve(to: CGPoint(x: 0.5677 * w, y: 0.1092 * h), control1: CGPoint(x: 0.5068 * w, y: 0.0719 * h), control2: CGPoint(x: 0.5405 * w, y: 0.0866 * h))
        p.addLine(to: CGPoint(x: 0.5618 * w, y: 0.1125 * h))
        p.addLine(to: CGPoint(x: 0.3627 * w, y: 0.2275 * h))
        p.addCurve(to: CGPoint(x: 0.3559 * w, y: 0.2327 * h), control1: CGPoint(x: 0.3602 * w, y: 0.2289 * h), control2: CGPoint(x: 0.3579 * w, y: 0.2307 * h))
        p.addCurve(to: CGPoint(x: 0.3507 * w, y: 0.2395 * h), control1: CGPoint(x: 0.3539 * w, y: 0.2347 * h), control2: CGPoint(x: 0.3522 * w, y: 0.2370 * h))
        p.addCurve(to: CGPoint(x: 0.3475 * w, y: 0.2474 * h), control1: CGPoint(x: 0.3493 * w, y: 0.2420 * h), control2: CGPoint(x: 0.3482 * w, y: 0.2446 * h))
        p.addCurve(to: CGPoint(x: 0.3463 * w, y: 0.2558 * h), control1: CGPoint(x: 0.3467 * w, y: 0.2501 * h), control2: CGPoint(x: 0.3463 * w, y: 0.2530 * h))
        p.addLine(to: CGPoint(x: 0.3461 * w, y: 0.5360 * h))
        p.move(to: CGPoint(x: 0.3918 * w, y: 0.4374 * h))
        p.addLine(to: CGPoint(x: 0.5003 * w, y: 0.3749 * h))
        p.addLine(to: CGPoint(x: 0.6089 * w, y: 0.4374 * h))
        p.addLine(to: CGPoint(x: 0.6089 * w, y: 0.5624 * h))
        p.addLine(to: CGPoint(x: 0.5006 * w, y: 0.6249 * h))
        p.addLine(to: CGPoint(x: 0.3920 * w, y: 0.5624 * h))
        p.addLine(to: CGPoint(x: 0.3918 * w, y: 0.4374 * h))
        return p
    }
}

/// Agent marker on a session card: branded icon, or the raw text for
/// agents we do not recognize (and for claude when Claude.app is absent).
struct AgentIcon: View {
    let agent: String
    let tk: Tokens

    var body: some View {
        switch agentKind(agent) {
        case .claude where claudeAppIcon != nil:
            Image(nsImage: claudeAppIcon!)
                .resizable()
                .frame(width: 13, height: 13)
                .help(agent)
        case .codex:
            CodexLogo()
                .fill(tk.t3)
                .frame(width: 13, height: 13)
                .help(agent)
        default:
            Text(agent)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tk.t3)
        }
    }
}
```

- [ ] **Step 4: Прогнать AgentIconTests**

Run: `swift test --filter AgentIconTests 2>&1 | tail -3`
Expected: PASS, 3 теста.

- [ ] **Step 5: Встроить в карточки и снести isClaudeAgent**

`Sources/covey/Views/SessionListView.swift` — в `card(_:number:)` два вхождения:

```swift
                        Text(session.agent).font(mono(11)).foregroundStyle(tk.t3)
```
(внутри `HStack` git-строки) и

```swift
                } else {
                    Text(session.agent).font(mono(11)).foregroundStyle(tk.t3)
                }
```
оба заменить на

```swift
                        AgentIcon(agent: session.agent, tk: tk)
```
и соответственно

```swift
                } else {
                    AgentIcon(agent: session.agent, tk: tk)
                }
```

`Sources/covey/Views/TerminalPaneView.swift:28`:

```swift
            if agentKind(session.agent) == .claude {
```

`Sources/covey/Views/UsageChip.swift` — удалить целиком:

```swift
/// Whether the chip applies to this session's agent (Claude only).
func isClaudeAgent(_ agent: String) -> Bool {
    agent.lowercased().contains("claude")
}
```

- [ ] **Step 6: Полный прогон**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: 0 failures.

- [ ] **Step 7: Commit (user)**

```bash
git add Sources/covey/Views/AgentIcon.swift Sources/covey/Views/SessionListView.swift Sources/covey/Views/TerminalPaneView.swift Sources/covey/Views/UsageChip.swift Tests/CoveyAppTests/AgentIconTests.swift
git commit -m "feat(covey): agent icons on session cards"
```

---

### Task 4: Смоук (user) + docs commit

Рестарт демона НЕ нужен — демон и протокол не менялись.

- [ ] **Step 1: Смоук по спеке §Смоук**

1. TopBar: кнопки темы нет, часы на месте; `space a t` переключает тему.
2. Usage-чип (claude-сессия, фокус на терминале): `5h NN% · XhYm` / `7d NN% · XdYh`; через минуту значение уменьшилось.
3. Карточки: claude-сессия — иконка Claude.app; codex-сессия — узел OpenAI в цвет темы; тултип показывает имя агента; пресет с иным именем — текст как раньше.

- [ ] **Step 2: Docs commit (user)**

```bash
git add docs/superpowers/plans/2026-07-04-covey-chrome-polish.md
git commit -m "docs: slice 21 implementation plan — chrome polish"
```
