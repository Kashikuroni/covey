# Smooth Scroll: Inline Claude + Precise Viewport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Плавный построчный скролл от точных дельт трекпада (с инерцией macOS) везде, где скроллит SwiftTerm, плюс перевод claude в inline-режим, чтобы его чат тоже скроллился нами.

**Architecture:** Демон добавляет `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1` в env-дефолты (fill-if-missing, как TERM). GUI перестаёт отдавать `.viewport`-колесо запечатанному `scrollWheel` SwiftTerm: чистый `WheelAccumulator` копит пиксели точных дельт и выдаёт целые строки (1 строка = rowHeight пикселей), momentum-события macOS дают инерцию бесплатно; дискретная мышь — 3 строки/щелчок. Клики по ссылкам в inline-чате открывает GUI (`requestOpenLink` + валидация схемы).

**Tech Stack:** Swift 6, SwiftTerm (без форка), XCTest.

**Spec:** `/covey/docs/superpowers/specs/2026-07-07-covey-smooth-scroll-inline-claude-design.md`

## Global Constraints

- Код, комментарии, commit-сообщения — английский (docs/ — русский).
- Git-записи делает ТОЛЬКО пользователь: в конце задачи предложи commit-сообщение и остановись.
- TDD: компилируемый скелет → падающий тест → реализация.
- SourceKit-фантомы при кросс-модульных правках игнорировать — верить `swift build`/`swift test`.
- GUI-тесты: `swift test --filter CoveyAppTests 2>&1 | tail -15`; демон: `--filter CoveydCoreTests`.
- Спека фиксирует: точные дельты → 1 строка на rowHeight px; мышь → 3 строки/щелчок; реверс направления сбрасывает остаток; `rowHeight <= 0` → no-op.

---

### Task 1: `WheelAccumulator`

**Files:**
- Create: `Sources/covey/WheelAccumulator.swift`
- Test: `Tests/CoveyAppTests/WheelAccumulatorTests.swift`

**Interfaces:**
- Consumes: только CoreGraphics (`CGFloat`).
- Produces: `struct WheelAccumulator { mutating func add(pixels: CGFloat, rowHeight: CGFloat) -> Int }` — знаковые целые строки; остаток хранится внутри. Task 2 держит его полем `CoveyTerminalView`.

- [ ] **Step 1: Скелет**

`Sources/covey/WheelAccumulator.swift` (новый файл):

```swift
import CoreGraphics

/// Accumulates precise (pixel) scroll deltas and converts them to whole
/// terminal lines. SwiftTerm's viewport scrolls line-by-line, while macOS
/// trackpads report sub-line pixel deltas at display rate; keeping the
/// fractional remainder between events makes slow drags advance smoothly
/// instead of quantizing into SwiftTerm's built-in 3-20 line jumps.
/// A direction reversal drops the remainder: a reversed finger must not
/// "pay back" leftover travel before the view starts moving.
struct WheelAccumulator {
    private var pixels: CGFloat = 0

    mutating func add(pixels delta: CGFloat, rowHeight: CGFloat) -> Int {
        0
    }
}
```

- [ ] **Step 2: Сборка**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Падающие тесты**

`Tests/CoveyAppTests/WheelAccumulatorTests.swift` (новый файл):

```swift
import XCTest
@testable import covey

final class WheelAccumulatorTests: XCTestCase {
    func testFractionsAccumulateToWholeLine() {
        var acc = WheelAccumulator()
        XCTAssertEqual(acc.add(pixels: 4, rowHeight: 10), 0)
        XCTAssertEqual(acc.add(pixels: 4, rowHeight: 10), 0)
        XCTAssertEqual(acc.add(pixels: 4, rowHeight: 10), 1)   // 12 px -> 1 line, 2 px kept
        XCTAssertEqual(acc.add(pixels: 8, rowHeight: 10), 1)   // 2 + 8 = 10 px
    }

    func testNegativeDeltasEmitNegativeLines() {
        var acc = WheelAccumulator()
        XCTAssertEqual(acc.add(pixels: -25, rowHeight: 10), -2) // -5 px kept
        XCTAssertEqual(acc.add(pixels: -5, rowHeight: 10), -1)
    }

    func testDirectionReversalDropsRemainder() {
        var acc = WheelAccumulator()
        XCTAssertEqual(acc.add(pixels: 9, rowHeight: 10), 0)
        XCTAssertEqual(acc.add(pixels: -9, rowHeight: 10), 0)   // NOT -1: +9 remainder dropped
        XCTAssertEqual(acc.add(pixels: -1, rowHeight: 10), -1)  // -9 + -1 = -10
    }

    func testLargeDeltaEmitsSeveralLinesAtOnce() {
        var acc = WheelAccumulator()
        XCTAssertEqual(acc.add(pixels: 35, rowHeight: 10), 3)
    }

    func testNonPositiveRowHeightIsNoop() {
        var acc = WheelAccumulator()
        XCTAssertEqual(acc.add(pixels: 100, rowHeight: 0), 0)
        XCTAssertEqual(acc.add(pixels: 100, rowHeight: -1), 0)
    }
}
```

- [ ] **Step 4: Убедиться, что падают**

Run: `swift test --filter CoveyAppTests.WheelAccumulatorTests 2>&1 | tail -8`
Expected: 4 из 5 FAIL по `XCTAssertEqual` (заглушка возвращает 0; no-op тест проходит).

- [ ] **Step 5: Реализация**

Заменить тело `add`:

```swift
    mutating func add(pixels delta: CGFloat, rowHeight: CGFloat) -> Int {
        guard rowHeight > 0 else { return 0 }
        if delta != 0, pixels != 0, (delta < 0) != (pixels < 0) {
            pixels = 0
        }
        pixels += delta
        let lines = Int(pixels / rowHeight)     // truncates toward zero
        pixels -= CGFloat(lines) * rowHeight
        return lines
    }
```

- [ ] **Step 6: Тесты зелёные**

Run: `swift test --filter CoveyAppTests.WheelAccumulatorTests 2>&1 | tail -5`
Expected: 5/5 PASS.

- [ ] **Step 7: Checkpoint — предложить коммит**

```
feat(covey): WheelAccumulator - pixel deltas to whole terminal lines
```

---

### Task 2: `CoveyTerminalView.scrollViewport` + перехват `.viewport`

**Files:**
- Modify: `Sources/covey/CoveyTerminalView.swift` (монитор ~строки 37-51 и новый метод)
- Test: `Tests/CoveyAppTests/CoveyTerminalViewTests.swift`

**Interfaces:**
- Consumes: `WheelAccumulator.add(pixels:rowHeight:)` (Task 1); публичные SwiftTerm: `getOptimalFrameSize() -> NSRect` (open), `getTerminal().rows`, `scrollUp(lines:)`, `scrollDown(lines:)`.
- Produces: `func scrollViewport(deltaY: CGFloat, precise: Bool)` (internal — тесты зовут напрямую); монитор глотает `.viewport`-события.

- [ ] **Step 1: Скелет метода**

В `CoveyTerminalView` после `wheelRoute()`:

```swift
    private var wheelAccumulator = WheelAccumulator()

    /// Precise viewport scrolling for the normal buffer: trackpad pixels
    /// accumulate into whole lines (momentum events arrive through the
    /// same path, so inertia comes from macOS for free); a discrete
    /// mouse-wheel notch scrolls the Terminal.app-standard 3 lines.
    func scrollViewport(deltaY: CGFloat, precise: Bool) {
    }
```

- [ ] **Step 2: Сборка**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Падающие тесты**

В `Tests/CoveyAppTests/CoveyTerminalViewTests.swift` добавить в класс:

```swift
    private func fillScrollback(_ view: CoveyTerminalView, lines: Int = 200) {
        for i in 0..<lines { view.feed(text: "line \(i)\r\n") }
    }

    func testPreciseDeltasScrollOneLinePerRowHeight() {
        let (view, _) = makeView()
        fillScrollback(view)
        let bottom = view.getTerminal().buffer.yDisp
        let rowHeight = view.getOptimalFrameSize().height
            / CGFloat(view.getTerminal().rows)
        view.scrollViewport(deltaY: rowHeight * 0.5, precise: true)
        XCTAssertEqual(view.getTerminal().buffer.yDisp, bottom)     // sub-line: no move
        view.scrollViewport(deltaY: rowHeight * 0.6, precise: true)
        XCTAssertEqual(view.getTerminal().buffer.yDisp, bottom - 1) // crossed one row
    }

    func testMouseNotchScrollsThreeLines() {
        let (view, _) = makeView()
        fillScrollback(view)
        let bottom = view.getTerminal().buffer.yDisp
        view.scrollViewport(deltaY: 1, precise: false)
        XCTAssertEqual(view.getTerminal().buffer.yDisp, bottom - 3)
        view.scrollViewport(deltaY: -1, precise: false)
        XCTAssertEqual(view.getTerminal().buffer.yDisp, bottom)
    }
```

- [ ] **Step 4: Убедиться, что падают**

Run: `swift test --filter CoveyAppTests.CoveyTerminalViewTests 2>&1 | tail -8`
Expected: оба новых FAIL (yDisp не двигается — метод пуст); старые тесты класса PASS.

- [ ] **Step 5: Реализация метода**

```swift
    func scrollViewport(deltaY: CGFloat, precise: Bool) {
        let lines: Int
        if precise {
            let rowHeight = getOptimalFrameSize().height
                / CGFloat(getTerminal().rows)
            lines = wheelAccumulator.add(pixels: deltaY, rowHeight: rowHeight)
        } else {
            lines = deltaY > 0 ? 3 : -3
        }
        if lines > 0 { scrollUp(lines: lines) }
        else if lines < 0 { scrollDown(lines: -lines) }
    }
```

- [ ] **Step 6: Перехват в мониторе**

В `viewDidMoveToWindow`, замыкание `wheelMonitor`. Было:

```swift
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window, event.deltaY != 0 else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                switch self.wheelRoute() {
                case .viewport:
                    return event                    // TerminalView scrolls the viewport
```

Стало (guard пропускает точные суб-строчные дельты, у которых `deltaY`
может округлиться в 0; `.viewport` глотает событие):

```swift
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window,
                      event.deltaY != 0 || event.scrollingDeltaY != 0 else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                switch self.wheelRoute() {
                case .viewport:
                    // Sealed scrollWheel would quantize into 3-20 line jumps;
                    // precise deltas + accumulator keep slow drags smooth.
                    self.scrollViewport(deltaY: event.hasPreciseScrollingDeltas
                                            ? event.scrollingDeltaY : event.deltaY,
                                        precise: event.hasPreciseScrollingDeltas)
                    return nil
```

Ветки `.mouseReport`/`.arrows` не меняются.

- [ ] **Step 7: Тесты зелёные (весь GUI-таргет)**

Run: `swift test --filter CoveyAppTests 2>&1 | tail -8`
Expected: все PASS (включая `testWheelReportSendsSGRWheelCodes` и route-тесты).

- [ ] **Step 8: Checkpoint — предложить коммит**

```
feat(covey): precise per-line viewport scrolling from trackpad deltas

Viewport wheel events no longer reach SwiftTerm's sealed scrollWheel
(3-20 line velocity jumps); a WheelAccumulator turns precise pixel
deltas into single-line scrolls, macOS momentum events ride the same
path, and a discrete mouse notch scrolls the standard 3 lines.
```

---

### Task 3: inline-режим claude в env-дефолтах демона

**Files:**
- Modify: `Sources/CoveydCore/SpawnEnvironment.swift`
- Test: `Tests/CoveydCoreTests/SpawnEnvironmentTests.swift`

**Interfaces:**
- Consumes: существующий `terminalEnvDefaults(_:) -> [(key: String, value: String)]` и его применение в `Sources/coveyd/main.swift` (setenv overwrite 0 — уже есть, не менять).
- Produces: дефолты включают `("CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN", "1")`.

- [ ] **Step 1: Падающий тест**

В `Tests/CoveydCoreTests/SpawnEnvironmentTests.swift` заменить два terminal-теста (список дефолтов растёт):

```swift
    // Finder/env -i case: children must still see a truecolor terminal,
    // or TUIs (claude) drop to monochrome.
    func testTerminalEnvDefaultsFillBareEnvironment() {
        let defaults = Dictionary(uniqueKeysWithValues:
            terminalEnvDefaults([:]).map { ($0.key, $0.value) })
        XCTAssertEqual(defaults["TERM"], "xterm-256color")
        XCTAssertEqual(defaults["COLORTERM"], "truecolor")
        XCTAssertEqual(defaults["LANG"], "en_US.UTF-8")
        // Inline claude: its transcript lives in the normal buffer, so the
        // GUI viewport (our smooth scrolling) scrolls the chat.
        XCTAssertEqual(defaults["CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"], "1")
    }

    func testTerminalEnvDefaultsNeverOverrideExisting() {
        let env = ["TERM": "screen", "LANG": "ru_RU.UTF-8",
                   "CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN": "0"]
        let keys = terminalEnvDefaults(env).map(\.key)
        XCTAssertEqual(keys, ["COLORTERM"])
    }
```

- [ ] **Step 2: Убедиться, что падают**

Run: `swift test --filter CoveydCoreTests.SpawnEnvironmentTests 2>&1 | tail -6`
Expected: `testTerminalEnvDefaultsFillBareEnvironment` FAIL (нет ключа CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN); override-тест PASS.

- [ ] **Step 3: Реализация**

В `Sources/CoveydCore/SpawnEnvironment.swift` расширить список в `terminalEnvDefaults` и дописать в doc-комментарий (после фразы про monochrome ASCII):

```swift
/// CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN rides along: inline-mode claude
/// keeps its transcript in the normal buffer, so the GUI viewport (and
/// covey's smooth scrolling) scrolls the chat. A user-provided value is
/// respected like any other entry.
```

```swift
    [("TERM", "xterm-256color"),
     ("COLORTERM", "truecolor"),
     ("LANG", "en_US.UTF-8"),
     ("CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN", "1")].filter { current[$0.0] == nil }
```

- [ ] **Step 4: Тесты зелёные**

Run: `swift test --filter CoveydCoreTests.SpawnEnvironmentTests 2>&1 | tail -4`
Expected: 6/6 PASS.

- [ ] **Step 5: Checkpoint — предложить коммит**

```
feat(coveyd): spawn claude in inline mode (no alternate screen)

The transcript stays in the normal buffer, so the GUI viewport scrolls
the chat with covey's smooth scrolling, and post-restart backfill
renders as readable conversation text instead of raw TUI frames.
```

---

### Task 4: клики по ссылкам в inline-чате

**Files:**
- Modify: `Sources/covey/TerminalController.swift:144` (`requestOpenLink`) и top-level функция в том же файле
- Modify: `docs/superpowers/specs/2026-07-07-covey-smooth-scroll-inline-claude-design.md` (§2.3, §5 — чистая функция вместо инжектируемого клоужера)
- Test: `Tests/CoveyAppTests/LinkURLTests.swift` (новый)

**Interfaces:**
- Consumes: ничего из других задач.
- Produces: `func linkURL(from link: String) -> URL?` (internal, top-level в TerminalController.swift); `Coordinator.requestOpenLink` открывает валидные URL через `NSWorkspace`.

- [ ] **Step 1: Скелет**

В `Sources/covey/TerminalController.swift` перед `struct TerminalRepresentable`:

```swift
/// URL for a terminal-reported link click. Only web schemes open: a TUI
/// can emit arbitrary OSC 8 targets, and file:/javascript: must not get
/// click-to-open semantics.
func linkURL(from link: String) -> URL? {
    nil
}
```

- [ ] **Step 2: Падающий тест**

`Tests/CoveyAppTests/LinkURLTests.swift` (новый файл):

```swift
import XCTest
@testable import covey

final class LinkURLTests: XCTestCase {
    func testWebSchemesPass() {
        XCTAssertEqual(linkURL(from: "https://example.com/a?b=1")?.absoluteString,
                       "https://example.com/a?b=1")
        XCTAssertNotNil(linkURL(from: "http://localhost:8080"))
        XCTAssertNotNil(linkURL(from: "HTTPS://EXAMPLE.COM"))   // scheme is case-insensitive
    }

    func testNonWebSchemesAndGarbageRejected() {
        XCTAssertNil(linkURL(from: "file:///etc/passwd"))
        XCTAssertNil(linkURL(from: "javascript:alert(1)"))
        XCTAssertNil(linkURL(from: "ssh://host"))
        XCTAssertNil(linkURL(from: "not a url"))
        XCTAssertNil(linkURL(from: ""))
    }
}
```

- [ ] **Step 3: Убедиться, что падают**

Run: `swift test --filter CoveyAppTests.LinkURLTests 2>&1 | tail -6`
Expected: `testWebSchemesPass` FAIL (nil), reject-тест PASS.

- [ ] **Step 4: Реализация + подключение**

```swift
func linkURL(from link: String) -> URL? {
    guard let url = URL(string: link),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else { return nil }
    return url
}
```

В `Coordinator` заменить пустую заглушку (строка ~144):

```swift
        // Inline-mode claude doesn't own the mouse, so the GUI opens link
        // clicks (alt-screen TUIs handled them via mouse reporting).
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = linkURL(from: link) else { return }
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
```

- [ ] **Step 5: Спека — синхронизировать §2.3 и §5**

В спеке заменить строку про «инжектируемый opener-клоужер» на: юнит-тест чистой `linkURL(from:)` (схемы http/https), открытие — напрямую `NSWorkspace` в `requestOpenLink`.

- [ ] **Step 6: Тесты зелёные + полный прогон**

Run: `swift test 2>&1 | grep -E "Executed .* tests, with|error:" | tail -3`
Expected: все таргеты PASS, 0 failures.

- [ ] **Step 7: Checkpoint — предложить коммит**

```
feat(covey): open http(s) links clicked in the terminal

Inline-mode claude no longer owns the mouse, so requestOpenLink stops
being a no-op: validate the OSC 8 target to web schemes and hand it to
NSWorkspace.
```

---

### Task 5: сборка бандла и smoke

**Files:** нет правок.

**Interfaces:**
- Consumes: собранные демон и GUI этой ветки.
- Produces: подтверждение сценария спеки §5.

- [ ] **Step 1: Пересобрать, убить старый демон**

```bash
swift test 2>&1 | grep -E "Executed .* tests, with" | tail -1
make install 2>&1 | tail -1
pkill -f coveyd; rm -f ~/.covey/coveyd.sock
```

Expected: тесты зелёные, `Installed /Applications/Covey.app`.

- [ ] **Step 2: Smoke (пользователь, глазами)**

1. Запустить Covey.app; демон поднимется новый (inline-env активен).
2. Рестарт claude-сессии (`space a u` или restart) → UI claude inline, ввод внизу.
3. Трекпад в agent-зоне: медленный драг двигает чат построчно без рывков 10+ строк; бросок — инерция macOS.
4. Колесо мыши: ровно 3 строки на щелчок.
5. Клик по http-ссылке в чате открывает браузер; `file:`-ссылки игнорируются.
6. vim в companion: колесо/стрелки как раньше (alt-screen путь не тронут).
7. Рестарт GUI: history чата — читаемый текст, скролл плавный.

- [ ] **Step 3: Отчёт**

Результаты — пользователю, с фактами. Не так — systematic-debugging, не латать вслепую.
