# Слайс 26 — vim-редактор с MD-preview для issue body (Design Spec)

> Description в issue-форме — vim: NORMAL/INSERT/VISUAL по сырцу +
> четвёртый режим PREVIEW (obsidian-подобный markdown-рендер,
> только вертикальный скролл). Номера строк во всех режимах. Ядро —
> чистая машина `VimEngine`; вью — переиспользуемый компонент
> `VimEditor`. Заодно issue-зона упрощается: форма всегда в фокусе,
> зонные ⌃-чорды пробиваются сквозь поля. GUI-only.

## 1. Поведение issue-зоны (упрощение слайса 25)

- Вход в issue-зону (⌃h/⌃l, ⌃j/⌃k, клик по табу, `space g i`) СРАЗУ
  фокусирует Title (`selectInspectorTab(.issue)` снова бампает
  `issueFocusTick`). «NORMAL-режим формы» и `KeyAction.inspectorEnter`
  удаляются (роутер, apply, тесты).
- Выход из зоны — зонные чорды работают ИЗ полей: ContentView
  key-monitor обрабатывает `⌃h ⌃l ⌃j ⌃k` ДО NSTextView-гарда, когда
  `model.focus == .inspector` (жертвуем emacs-биндингами NSTextView в
  этой зоне — осознанно). `⌘M/⌘O` работают как раньше; Esc в Title —
  no-op (onExitCommand убрать); Esc в body — дело vim-движка.

## 2. VimEngine (`Sources/covey/VimEngine.swift`, чистый)

```swift
struct VimEngine {
    enum Mode: Equatable { case normal, insert, visual(anchor: Int), preview }
    private(set) var text: String
    private(set) var cursor: Int          // character offset
    private(set) var mode: Mode
    private(set) var pending: Character?  // d / c / y operator
    private(set) var pendingG: Bool       // g prefix (gg / gp)
    private(set) var count: Int?          // motion count prefix (12G, 5j)
}

enum VimInput: Equatable {
    case char(Character)
    case escape
    case tab, shiftTab
}

enum VimEffect: Equatable {
    case none
    case setPasteboard(String)
    case switchField(forward: Bool)
    case scrollCenter                     // zz in preview
}

mutating func handle(_ input: VimInput, pasteboard: () -> String?) -> VimEffect
mutating func syncFromView(text: String, cursor: Int)  // after native INSERT
```

Клипборд через параметры/эффекты; linewise-yank кодируется
завершающим `\n` (dd/yy кладут строку с \n, `p` вставляет строкой).

### Команды NORMAL / VISUAL (по сырцу)

- Движения: `h l j k`, `w b`, `0 $`, `gg G` — все с числовым префиксом
  (`5j`, `3w`, `12G` — строка 12; `G` без счёта — последняя строка).
  Счётчики ТОЛЬКО для движений (2dd НЕ делаем).
- INSERT: `i a I A o O`; Esc → NORMAL (каретка на символ влево).
- Правки: `x`; `dd yy cc`; операторы `d c y` + движение; `p P`
  (из системного буфера, linewise по `\n`).
- VISUAL: `v`, движения растят выделение, `d`/`x`/`y`/`c`, Esc.
  Посимвольный (V-line НЕ делаем).
- `Tab`/`⇧Tab` в NORMAL → `.switchField(forward:)`.
- `gp` в NORMAL → PREVIEW (g-префикс общий с gg).
- НЕ делаем: регистры кроме системного, `u`/`⌃r` в NORMAL, `V`/`⌃v`,
  поиск, точка-повтор, счётчики операторов.

### PREVIEW

- Вход `gp`, выход Esc → NORMAL (cursor не меняется).
- Только вертикаль: `j k` (+счётчики), `gg`, `G`, `<N>G` — прыжок на
  строку N, `zz` → эффект `.scrollCenter`. Горизонтали/правок нет; все
  прочие клавиши — no-op. Движение двигает `cursor` построчно (колонка
  0) — вью скроллит к строке курсора.

### Границы

Пустой текст; NORMAL-кламп каретки на последний символ строки; `dd`
единственной строки → пустая; `x` в пустой строке no-op; невалидное
движение сбрасывает pending/count; счётчик клампится в границы.

## 3. VimEditor (`Sources/covey/Views/VimEditor.swift`, переиспользуемый)

```swift
struct VimEditor: View {
    @Binding var text: String
    @Binding var modeBadge: String   // "NORMAL"/"INSERT"/"VISUAL"/"PREVIEW"
    var tk: Tokens
    var onSwitchField: (Bool) -> Void
}
```

- **normal/insert/visual** — NSViewRepresentable поверх NSTextView в
  NSScrollView: INSERT нативный (Esc перехвачен), NORMAL/VISUAL —
  полный keyDown-перехват → engine; selectedRange = каретка/выделение;
  `.setPasteboard` → NSPasteboard.
- **Номера строк** — свой `LineNumberRuler: NSRulerView` на скролл-вью
  (mono 10, tk.t4), во всех текстовых режимах.
- **preview** — вместо текст-вью SwiftUI ScrollView + ScrollViewReader:
  построчный markdown-рендер (движок `parseNote` из NoteModel:
  заголовки/жирные/списки/чекбоксы; сырая строка ↔ строка рендера 1:1),
  слева номер строки; строка курсора подсвечена (`tk.surf2`);
  движение → `scrollTo(line, anchor: nil)`, `.scrollCenter` →
  `scrollTo(line, anchor: .center)`.
- Каретка визуально обычная; режим — бейджем футера.
- Стили: mono 12, ayu-рамка (фокус — accent), фон surf2 — как текущее
  body-поле.

## 4. Интеграция

- IssuePane: body `TextEditor` → `VimEditor` (binding в драфт;
  `onSwitchField` → фокус Title; высота 140 как сейчас).
- Футер-бейдж: `AppModel.inspectorVimBadge: String?` (transient) —
  VimEditor пишет режим, Title-фокус — "INSERT", без фокуса nil.
  StatusBar: `inspectorVimBadge ?? (noteState.editing ? "INSERT" :
  "NORMAL")`; цвета: INSERT — tk.warn, VISUAL — tk.accent, PREVIEW —
  tk.ok, NORMAL — tk.t4.
- Note-pane остаётся как есть (переезд на VimEditor — будущий слайс).

## 5. Тесты (VimEngineTests, новый)

- Движения ± счётчики (5j, 3w, 12G, кламп), hjkl-границы, 0/$, gg/G.
- INSERT-входы/Esc-сдвиг; syncFromView.
- x, dd/yy/cc (linewise \n), dw/d$/dj/cw/yw, p/P (символьный и
  строчный).
- VISUAL: v+движение+d/y/c/x, Esc.
- Tab/⇧Tab → .switchField только из NORMAL.
- PREVIEW: gp вход, Esc выход, j/k/G/gg/<N>G движение по строкам,
  zz → .scrollCenter, правки игнорируются (x/dd в preview — no-op).
- Сброс pending/count невалидным вводом.
- Зона: ⌃h/⌃l из поля уводят фокус (KeyRouter/monitor — существующие
  тесты роутера + ручной смоук); удаление inspectorEnter чинит его
  тесты.

## 6. Смоук (user)

Рестарт демона не нужен.

1. Переход на Issue любым способом — курсор сразу в Title; ⌃h/⌃l
   ИЗ Title/body уводят по зонам; ⌘M/⌘O работают при вводе.
2. Body: INSERT-печать; Esc → NORMAL (футер), hjkl/w/b/0/$/5j/12G;
   i/a/o/A корректные позиции.
3. dd/p, yy/p, x, dw, cw; v+движение → VISUAL (футер, акцент), y/d.
4. `gp` → PREVIEW (футер, зелёный): MD-рендер с номерами строк,
   заголовки/списки/чекбоксы как в obsidian-чтении; j/k/5j/gg/G/12G
   скроллят, zz центрирует; Esc → NORMAL (сырец, каретка на месте).
5. Номера строк видны и в текстовых режимах.
6. Tab из body-NORMAL → Title; Esc в Title ничего не ломает.
