# Slice 12 — vim-ядро: режимы, KeyRouter, leader, ⌃Q (Design Spec)

> Дата: 2026-07-02
> Источник: инвентаризация `amux-tui` (крейт `~/projects/pets/agents_multiplexer/crates/amux-tui`,
> `app.rs` — стейт-машина, `ui/leader.rs` — дерево чордов, `ui/footer.rs` — подсказки,
> `amux-core/keymap.rs` — латинизация). Направление: память `keyboard-first-priority`.
> Решения: vim-режим включён по умолчанию; выход из терминала — ⌃Q (Control, не ⌘),
> запасной путь ⌘⇧1/2/3 остаётся.

## 0. Контекст

Фаза 2 — порт функционала TUI-версии, клавиатура первична. Срез 12 закладывает
ядро: модальную стейт-машину ввода, маршрутизацию клавиш между списком и живым
терминалом, leader-чорды со which-key-панелью, реальный first-responder-фокус.
Последующие срезы (заметки, reply, prompts, git-действия) добавляют команды в
уже существующее дерево.

## 1. KeyRouter — чистая стейт-машина

Новый `/covey/Sources/covey/KeyRouter.swift`. Порт философии `App::handle_key`
из TUI: функция без IO, юнит-тестится таблично.

```swift
struct KeyInput: Equatable {           // абстракция NSEvent.keyDown
    var char: Character?               // charactersIgnoringModifiers, первый символ
    var isControl: Bool                // ⌃ (macOS Control)
    var isShift: Bool
    var special: Special?              // enum: escape, enter, tab, backTab, backspace,
                                       // up, down, left, right, pageUp, pageDown, end
}

enum KeyAction: Equatable {
    case selectNext, selectPrev, selectFirst
    case enterTerminal                 // аналог attach: фокус в терминал
    case exitTerminal                  // ⌃Q из терминала
    case toggleTab                     // Current ↔ Recent
    case newSession(prefillDir: Bool)  // n / N
    case killSelected                  // d
    case startFilter                   // '/'
    case openLeader
    case leaderDescend(LeaderMenu)     // g / s / a
    case leaderBack                    // Backspace
    case closeOverlay                  // Esc: leader/select/help
    case renameSelected                // leader s r
    case enterSelectMode               // s
    case selectByNumber(Int)           // 1-9 в select-режиме
    case resizeSplit(Int)              // ±3 / ±8 (проценты)
    case moveSelected(up: Bool)        // K / J
    case scrollTerminalPage(up: Bool)  // ⌃k / ⌃j, PageUp/PageDown
    case scrollTerminalToBottom        // G / End
    case showHelp                      // ?
}
```

`KeyRouter.route(_ input: KeyInput, context: Context) -> KeyAction?` где
`Context = (mode: InputMode, focus: Focus, vimMode: Bool, sheetOpen: Bool)`.
Правила:
- `sheetOpen == true` → всегда `nil` (шиты обрабатывают ввод сами).
- `focus == .terminal` → только `⌃Q → .exitTerminal`, всё остальное `nil`
  (уходит в pty).
- `vimMode == false` → `nil` (кроме ничего: мышь и ⌘-меню работают всегда).
- Иначе — таблица биндингов по `mode` (см. §3–4).

Латинизация: порт `amux-core/keymap.rs::latinize` — приватная таблица
кириллица→латиница по физической позиции QWERTY/ЙЦУКЕН (`й→q, ц→w, …`),
применяется к `char` ПЕРЕД матчингом чордов; текстовые поля (фильтр и будущие
редакторы) получают символы сырыми, роутер их не трогает.

## 2. InputMode и AppModel

- `enum InputMode: Equatable { case normal, leader(LeaderMenu), selectSession, help }`
  (`enum LeaderMenu { case root, git, session, app }`); фильтр остаётся полем
  `filter` + фокусом текстового поля (существующий механизм) — режим не нужен.
- `AppModel`: `inputMode: InputMode = .normal` (transient), `setInputMode`.
- `vimMode` дефолт меняется на **true** (`persisted.vimMode ?? true`).
- Применение `KeyAction` — `AppModel.apply(_ action: KeyAction)` (MainActor):
  selectNext/Prev идут по плоскому порядку `orderedSessions()` c учётом фильтра;
  moveSelected → существующий `moveSession(inDir:from:to:)` (свопы project у
  края группы — как в TUI, later slice, пока в пределах группы);
  resizeSplit → `setSplitPct(splitPct + delta)`; enterTerminal/exitTerminal →
  `setFocus` + запрос first responder (см. §5); killSelected/renameSelected →
  существующие `Modal`; newSession(prefillDir) → `.newSession` (префилл дира
  выбранной сессии — поле в NewSessionSheet уже есть, передаём начальное
  значение); selectByNumber → выбор n-й видимой сессии; scrollTerminal* → новые
  колбэки к терминалу (см. §5); showHelp → `inputMode = .help`.

## 3. Биндинги normal-режима (порт List из app.rs:1661)

| Клавиша | Действие |
|---|---|
| `j` / `↓` | selectNext |
| `k` / `↑` | selectPrev |
| `g` | selectFirst |
| `Enter` / `o` | enterTerminal (Recent-таб: relaunch выбранной recent) |
| `Tab` | toggleTab |
| `n` / `N` | newSession(prefillDir: false / true) |
| `d` | killSelected |
| `/` | startFilter (фокус в поле фильтра) |
| `s` | enterSelectMode; затем `1-9` → selectByNumber, `Esc` — отмена |
| `Space` | openLeader |
| `K` / `J` | moveSelected(up/down) |
| `[` / `]` | resizeSplit(∓3) |
| `{` / `}` | resizeSplit(∓8) |
| `⌃←` / `⌃→` | resizeSplit(∓8) |
| `G` / `End` | scrollTerminalToBottom |
| `⌃k` / `PageUp` | scrollTerminalPage(up) |
| `⌃j` / `PageDown` | scrollTerminalPage(down) |
| `?` | showHelp |

Не в этом срезе (появятся со своими фичами): `1-9` ответы на промпты, `i`,
`t`/`T`, `v`/`V`, `e`, `⌃r`, `q` (в GUI есть ⌘Q), `Shift+Tab`.

## 4. Leader-дерево и which-key

Полное дерево TUI (`ui/leader.rs:10-27`), нереализованные команды видимы, но
серые с пометкой «later»:

```
Space →
  g  git      i issue(later) · p promote(later) · b delete branch(later) · c cleanup(later)
  s  session  r rename · R rename project(later) · v verify(later) · V details(later) · e nvim(later)
  a  app      l usage log(later) · u restart claude(later)
```

- Реализовано в этом срезе: `s r` → Rename-шит выбранной сессии.
- `Backspace` — на уровень вверх, `Esc`/несвязанная клавиша — закрыть,
  таймаута нет (как в TUI).
- Which-key-панель: SwiftUI-оверлей над статус-баром (порт `ui/leader.rs:41`) —
  строки `клавиша — описание`, серым для «later». Показывается при
  `inputMode == .leader`.

## 5. Роутинг ввода и first-responder

- Существующий keyDown-монитор в `ContentView` расширяется: строит `KeyInput`
  из NSEvent, зовёт `KeyRouter.route`, действие → `model.apply`, событие
  гасится; `nil` — событие проходит дальше (в т.ч. прежний ⌘W-перехват
  сохраняется как отдельная ветка).
- **First responder**: `enterTerminal` → `window.makeFirstResponder(terminalView)`;
  `exitTerminal` (⌃Q) → `makeFirstResponder(nil)` + `setFocus(.sessions)`.
  Терминал-view доступен через колбэк: `AppModel.onTerminalCommand:
  ((TerminalCommand) -> Void)?` где `enum TerminalCommand { case focus,
  scrollPage(up: Bool), scrollToBottom }` — ставится в
  `TerminalRepresentable.makeNSView` (по образцу `onTerminalOutput`),
  реализуется через public API SwiftTerm (`scrollUp/scrollDown(lines:)`,
  `scroll(toPosition: 1.0)`, `window?.makeFirstResponder(view)`).
- Клик по терминалу по-прежнему ставит `focus = .terminal` (мышь вторична, но
  работает); клик по списку возвращает `.sessions`.
- ⌃Q матчится ТОЛЬКО при `focus == .terminal`; NSEvent `.control` — это
  клавиша Control (⌃), не Command.
- **Guard текстового ввода**: если first responder окна — текстовое поле
  (field editor / `NSTextView`), монитор возвращает событие нетронутым —
  роутер не видит клавиш, пока пользователь печатает в фильтре или шите.
  Esc в поле фильтра обрабатывает само поле (`.onExitCommand` SwiftUI):
  очищает фильтр и возвращает фокус списку — «Esc из фильтра — назад» из DoD.

## 6. Хром

- **StatusBar**: подсказки по режиму (порт `ui/footer.rs::items_for`):
  - normal: `n new · enter attach · d kill · space menu · / filter · ? help`;
  - терминал в фокусе: `⌃q back to list`;
  - leader: `esc close · backspace back`;
  - select: `1-9 jump · esc cancel`.
- **Help-оверлей** (`?`): полупрозрачная панель поверх workspace (не шит —
  закрывается любой клавишей, как в TUI) со сгруппированной справкой клавиш,
  включая полное leader-дерево. Скролл не нужен (одна страница), changelog-таб
  — N/A.
- Индикатор режима в статус-баре: `NORMAL`/`LEADER`/`SELECT` рядом с меткой
  фокуса (vim выключен — пусто).

## 7. Тесты

- **KeyRouterTests** (новый): табличные тесты биндингов normal-режима;
  leader-дерево (root→group→команда, Backspace, Esc, несвязанная клавиша);
  select-режим (1-9, Esc, прочее игнор); `⌃Q` только при `focus == .terminal`;
  `sheetOpen` глушит всё; `vimMode == false` глушит всё; латинизация
  (`о→j`-эквивалент: `й→q`, `в→d`, проверить 3-4 пары + текст в фильтр сырой).
- **AppModelChromeTests** (дополнение): `apply(.selectNext/Prev)` ходит по
  `orderedSessions` c фильтром; `apply(.selectByNumber)`; `apply(.resizeSplit)`
  клампится существующим `setSplitPct`; `inputMode` переходы; дефолт
  `vimMode == true` на пустом стейте.
- Which-key/help/first-responder — смоук.

## 8. Границы

- Не трогаем: демон, IPC, протокол.
- Не делаем: команды «later» из дерева, ответы 1-9, reply/notes, project-swap
  при реордере у края группы, changelog в help.

## 9. Definition of Done

1. Сборка + полный набор тестов зелёные.
2. Смоук (клавиатура, мышь не используется):
   - `j/k/g` ходят по списку, `Tab` — Recent и обратно, `/` — фильтр, Esc из
     фильтра — назад;
   - `Enter` — фокус в терминал (ввод уходит агенту), `⌃Q` — назад в список;
   - `n` — New-шит, `d` — Kill-шит, `s`+`2` — прыжок ко второй сессии;
   - `Space` — which-key, `s`→`r` — Rename-шит, серые пункты не реагируют,
     `Esc` закрывает;
   - `[`/`]`/`{`/`}` двигают сплит, `K/J` переставляют сессии, `G`/`⌃k`/`⌃j`
     скроллят терминал;
   - `?` — справка, любая клавиша закрывает;
   - на ЙЦУКЕН-раскладке `о`(=j)/`л`(=k) ходят по списку;
   - View→Vim Mode off: буквы не перехватываются, мышь/⌘ работают.
3. Индикатор режима и подсказки в статус-баре соответствуют режиму.
