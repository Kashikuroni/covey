# Плавный скролл: inline claude + точные дельты viewport (Design Spec)

> **Ревизия 2026-07-07 (после smoke):** §1 (inline-режим claude) ОТКАЧЕН.
> Каждый resize agent-пейна (тогл/драг сплита) превращал normal-buffer
> транскрипт в кашу: reflow ломает строки, отрендеренные под старую
> ширину (ink центрирует пробелами), а перерисовка ink на SIGWINCH
> оставляет в scrollback дубли блоков. Пользователь часто открывает
> terminal-сплит — цена выше пользы. Чат claude снова alt-screen
> (скроллит сам, построчно). §2 (точный viewport-скролл), §2.3 (ссылки)
> и снап-гейт остаются — работают для terminal-пейна и истории
> normal-buffer сессий. Снап из slice 9 дополнительно огейчен зажатой
> ЛКМ (только реальный драг ползунка).

> «Как на телефоне» упирается в два факта: чат живого claude в alt screen
> скроллит сам claude (построчно, пикселей в протоколе нет), а SwiftTerm
> на macOS квантует колесо в рывки по 3–20 строк
> (`calcScrollingVelocity`). Решение из двух половин: claude переводится
> в inline-режим (транскрипт в normal buffer → скроллим мы), а
> viewport-скролл переходит на точные попиксельные дельты трекпада —
> одна строка на каждые rowHeight пикселей, momentum бесплатно от macOS.
> Субпиксель не делаем: требует форка SwiftTerm (draw запечатан,
> пиксельный contentOffset есть только в iOS-ветке рендерера) — решено
> отказаться.

## 0. Контекст

- Route `.viewport` сейчас отдаёт событие запечатанному
  `scrollWheel` SwiftTerm → `calcScrollingVelocity` → прыжки 3/10/20+
  строк. Точные дельты (`hasPreciseScrollingDeltas`,
  `scrollingDeltaY` в пикселях, momentum-фазы) macOS уже шлёт — они
  просто выбрасываются.
- `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1` проверен пробой на 2.1.201:
  claude не включает ни `?1049h`, ни mouse tracking (только
  2004/1004/2031/2026/25) → колесо в agent-зоне идёт в `.viewport`.
- Без alt-screen claude не захватывает мышь → ссылки из чата он сам не
  откроет; `requestOpenLink` в `TerminalController` сейчас пуст
  (памятка slice 9, п. 6).

## 1. Inline-режим claude

- Пара `("CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN", "1")` добавляется в
  список `terminalEnvDefaults` (CoveydCore/SpawnEnvironment.swift) —
  fill-if-missing семантика уже есть, оттестирована и применяется в
  `main.swift`; пользовательское значение не перетирается.
- Переменную читает только claude; шеллам/vim безразлична.
- Действует на новые сессии и рестарты (`space a u`); живые сессии не
  трогаем.
- Откат фичи = удалить одну строку.
- Следствия: транскрипт claude в normal buffer → viewport-скролл,
  history-badge, осмысленный backfill после рестарта covey (текст, а не
  кадры TUI).

## 2. Точный viewport-скролл

### 2.1 `WheelAccumulator` (новый чистый тип, GUI)

- `Sources/covey/WheelAccumulator.swift`:
  `struct WheelAccumulator { mutating func add(pixels: CGFloat, rowHeight: CGFloat) -> Int }`
  — копит пиксели, возвращает целые строки (знаковые), остаток хранит;
  смена знака — остаток обнуляется (естественное ощущение реверса);
  `rowHeight <= 0` → 0 строк, состояние не меняется.
- Без AppKit — юнит-тестируется напрямую.

### 2.2 `CoveyTerminalView` (wheel monitor)

- Route `.viewport` больше не возвращает событие SwiftTerm — обрабатываем
  и возвращаем nil:
  - `event.hasPreciseScrollingDeltas == true` (трекпад): пиксели
    `event.scrollingDeltaY` → аккумулятор → `scrollUp(lines:)` /
    `scrollDown(lines: |n|)` по знаку. Momentum-события приходят тем же
    путём — инерция бесплатно.
  - `false` (мышиное колесо): 3 строки на щелчок
    (`deltaY > 0 ? scrollUp(lines: 3) : scrollDown(lines: 3)`), без
    синтетической инерции.
- `rowHeight = getOptimalFrameSize().height / CGFloat(terminal.rows)`
  (публичный API SwiftTerm; cellDimension внутренний).
- Аккумулятор — поле вьюхи (один жест — одна вьюха; сплит-пейны не
  делят состояние).

### 2.3 Ссылки в inline-чате

- Чистая top-level `linkURL(from: String) -> URL?` в
  TerminalController.swift: схема строго `http`/`https`, иначе nil.
  `Coordinator.requestOpenLink` зовёт её и открывает через
  `NSWorkspace.shared.open` (hop на main). Остальные схемы игнорируются
  молча.

## 3. Взаимодействие с attach-преамбулой (слайс 2026-07-07)

- Преамбула остаётся нужной: vim/lazygit и любые alt-screen TUI в
  terminal-пейне. Для inline-claude она почти пуста (2004h) — корректно.
- Alt-buffer ветка `scrolled()`-коордиатора для inline-claude не
  срабатывает (normal buffer) — history-badge работает штатно.

## 4. Не делаем (non-goals)

- Субпиксельный рендер и форк SwiftTerm.
- Синтетическая инерция для дискретного мышиного колеса.
- Пер-сессионный тогл inline/alt-screen.
- Плавность встроенных TUI (vim и чат claude в alt-screen, если
  пользователь вернёт alt-режим руками).

## 5. Тесты

- **Unit `WheelAccumulator`:** дробное накопление (0.4+0.4+0.4 строки →
  1 строка на третьем добавлении, остаток 0.2); знак вниз; смена знака
  сбрасывает остаток; большая дельта → несколько строк за раз;
  `rowHeight <= 0` → 0.
- **Unit `SpawnEnvironmentTests`:** `terminalEnvDefaults([:])` содержит
  `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1`; при уже заданном значении
  пара не возвращается (fill-if-missing).
- **Unit `linkURL(from:)`:** валидация схем (`http`/`https` проходят,
  `file`/`javascript`/мусор — nil); открытие — напрямую `NSWorkspace`
  в `requestOpenLink`, без инжекции.
- **Smoke:** рестарт claude-сессии → inline UI; трекпад: скролл чата
  плавный построчный с инерцией, без рывков 10+ строк; колесо мыши:
  3 строки/щелчок; клик по ссылке в чате открывает браузер; vim в
  companion скроллится как раньше.
