# Слайс 20 — хром + Ayu (Design Spec)

> Пять правок хрома/UX + перевод всей программы на палитру ayu (dark =
> Mirage, light = Ayu Light). Дизайн утверждён в компаньоне
> (`chrome-ayu.html`). Значения цветов — литералы из
> `ayu-theme/ayu-colors/themes/{mirage,light}.yaml`.

## 1. Ayu-палитра в Tokens

Структура `Tokens` и все места использования НЕ меняются — только значения
и один новый токен `accent`.

| Токен | Mirage (dark) | Light |
|---|---|---|
| bg | `#181C26` (surface.sunk) | `#EBEEF0` |
| surface | `#1F2430` (base) | `#F8F9FA` |
| surf2 | `#242936` (lift) | `#FCFCFC` |
| surf3 | `#282E3B` (panel) | `#FFFFFF` |
| surf4 | `#6E7C8F` @ 0.4 (gray-альфа) | `#ADAEB1` @ 0.5 |
| card | `#242936` | `#FCFCFC` |
| cardHover | `#282E3B` | `#FFFFFF` |
| termBg | `#242936` (editor.bg = lift) | `#FCFCFC` |
| bd | `#171B24` solid (ui.line) | `#6B7D8F` @ 0.12 |
| bd2 | `#6E7C8F` @ 0.25 | `#6B7D8F` @ 0.20 |
| bd3 | `#6E7C8F` @ 0.45 | `#6B7D8F` @ 0.32 |
| t1 | `#CCCAC2` (editor.fg) | `#5C6166` |
| t2 | `#CCCAC2` @ 0.8 | `#787B80` |
| t3 | `#707A8C` (ui.fg) | `#828E9F` |
| t4 | `#707A8C` @ 0.6 | `#ABB2BD` |
| run | `#FFA659` (orange) | `#FA8532` |
| wait | `#FFCD66` (yellow) | `#EBA400` |
| idle | `#282E3B` | `#CED4DA` |
| ok / diffAdd | `#87D96C` (vcs.added) | `#6CBF43` |
| err / diffDel | `#F27983` (vcs.removed) | `#FF7383` |
| warn | `#D9BE98` (peach) | `#E59645` |
| shadowColor | black @ 0.2 (panel.shadow) | `#6B7D8F` @ 0.1 |
| **accent** (новый) | `#FFCC66` (common.accent) | `#F29718` |

- `ContentView` корень получает `.tint(tk.accent)` — glassProminent-кнопки
  и системные контролы красятся в ayu-акцент.
- `TokensTests` обновляются под новые значения (+ accent).

### Терминал (Theme.swift + TerminalController)

- `Theme` дополняется `ansi: [NSColor]` (16 цветов; часть значений в
  yaml вычисляемая — берём ближайшие ЛИТЕРАЛЫ той же темы, ничего не
  изобретаем):
  - Mirage: black `#0A0000`, red `#F28779`, green `#D5FF80`,
    yellow `#FFCD66`, blue `#73D0FF`, magenta `#DFBFFF`, cyan `#95E6CB`,
    white `#CCCAC2` (editor.fg); bright: brightBlack `#6E7C8F` (gray),
    red…cyan — те же шесть акцентов, brightWhite `#FFFFFF`
    (surface.over).
  - Light: black `#5C6166` (editor.fg), red `#F07171`, green `#86B300`,
    yellow `#EBA400`, blue `#22A4E6`, magenta `#A37ACC`, cyan `#4CBF99`,
    white `#ADAEB1` (gray); bright: brightBlack `#828E9F` (ui.fg),
    red…cyan — те же, brightWhite `#FFFFFF` (surface.over).
- `background`/`foreground`/`cursor` в `Theme`: dark → `#242936` /
  `#CCCAC2` / `#FFCC66`; light → `#FCFCFC` / `#5C6166` / `#F29718`.
- `TerminalController.applyTheme` дополнительно ставит ANSI-палитру
  (`view.installColors(...)` — точное API SwiftTerm сверить при
  реализации: `installColors(_: [SwiftTerm.Color])`).

## 2. TopBar на уровне светофора

- Окно: `.windowStyle(.hiddenTitleBar)` у WindowGroup (title скрыт,
  контент под titlebar); высота бара ~38, отступ слева ~78 под traffic
  lights.
- Содержимое: `covey` (t1, semibold) · счётчики `N · ▶R · ⏸W`
  (mono, t3) · Spacer · тема-тоггл (остаётся, borderless) · часы
  (mono, t3, как сейчас TimelineView).
- Удаляются: `Picker Standard/Git` и `enum ViewKind` целиком.
- Фон бара `surface`, нижняя граница `bd`.

## 3. Кнопка «+»

- `.toolbar { Button(plus) }` из `SessionListView` удаляется (создание —
  `⌘N`/`n`/`N`). `.windowStyle(.hiddenTitleBar)` убирает и сам тулбар.

## 4. Recent → таб в NewSessionSheet

- Из главного окна удаляются: сегмент Active/Recent (`Picker` в
  `SessionListView`), `recentList`, `AppModel.ListTab`, `listTab`,
  `setListTab`, `recentSelected`, `toggleTab`-экшен (и `Tab`-чорд в
  KeyRouter + его тест), recent-ветки в `jump(to:)` и `.enterTerminal`.
  `visibleRecents`, `relaunchRecent`, `recents` остаются (нужны шиту).
- `NewSessionSheet` получает сверху сегмент `New | Recent`
  (`@State tab`), Recent-таб:
  - список `model.visibleRecents()` в стиле Recent-строк среза 19
    (`↻`, mono-имя, агент+путь, возраст `humanizeAge`);
  - клавиатура: `↑/↓` ходят, `Enter` → `relaunchRecent` + закрыть шит;
    клик по строке — то же; `Esc` закрывает шит (как сейчас);
  - пустой список → `no recently-stopped sessions` (t4, по центру).
- `WhichKey`/`HelpOverlay`/`StatusBar` упоминания Tab-переключения
  списка удаляются.

## 5. Фильтр в футере

- Постоянный `TextField` фильтра из `SessionListView` удаляется;
  `filterFocusTick` и `requestFilterFocus` умирают.
- `AppModel` + `filterActive: Bool`. `/` (и `⌘F`) → `filterActive = true`.
- `StatusBar`: при `filterActive` вместо хинтов — строка
  `/ [TextField] N/M`, где N = отфильтрованных, M = всего; поле
  автофокусируется. Правая часть (mode/HISTORY/focus) остаётся.
- Клавиши в активном фильтре (обрабатываются на поле):
  - `Esc` → `filter = ""`, `filterActive = false`, фокус в список;
  - `⌃j`/`⌃k` и `↓`/`↑` → selectNext/selectPrev по отфильтрованному
    списку (буквы j/k печатаются в текст);
  - `Enter` → `filter = ""`, `filterActive = false`, фокус в терминал
    выбранной (`enterTerminal`-путь). Пустой результат фильтра → Enter
    no-op.
- Подсветка выбранной карточки при навигации работает как обычно
  (selection живёт в model).

## 6. Границы

- Git-view и любые git-кнопки в хроме — нет (git-работа отдельным
  концептом позже).
- Inspector, sheets-вёрстка (кроме Recent-таба), notes — не трогаем;
  они уже на токенах или системные.
- Vim-режим/чорды не меняются (кроме удалённого Tab).

## 7. Тесты

- `TokensTests` — новые ayu-значения (dark.bg `#181C26`,
  light.card `#FCFCFC`, accent оба, спот-чек).
- `ThemeTests`/расширение существующих: `ansi.count == 16` для обеих тем,
  спот-чек пары цветов.
- KeyRouter: `/` → startFilter остаётся; `Tab` больше не toggleTab
  (тест обновить/удалить).
- AppModel: `filterActive` — `/`-экшен включает; Esc-путь чистит фильтр
  (юнит через apply, если экшены появятся; иначе смоук).
- Смоук: топбар на уровне светофора без Standard/Git; `+` отсутствует;
  ayu в тёмной/светлой теме (список, терминал с ANSI-цветами, glass);
  `⌘N` → шит с табом Recent, Enter релончит; `/` → футер-фильтр,
  ⌃j/⌃k/стрелки ходят, Enter в терминал, Esc закрывает.
