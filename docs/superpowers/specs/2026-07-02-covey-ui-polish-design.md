# Slice 11 — UI-добивка: Inspector, Session-меню, ⌘W/⌘1-2-3, vim-заглушка (Design Spec)

> Дата: 2026-07-02
> Источник: HANDOFF §6 (inspector + sb_width), §7 (Focus/⌘-шорткаты, vim-тумблер),
> §12 DoD п.6 — закрывает последний гэп фазы 1. Решения согласованы:
> инспектор за тогглом (по умолчанию скрыт), ⌘W = Kill-шит выбранной сессии.

## 0. Контекст

После срезов 5–10 из фазы-1 HANDOFF не сделано: Inspector-плейсхолдер с
персистом ширины (`sb_width`), Session-меню, ⌘W/⌘1/⌘2/⌘3, vim-тумблер.
Расширение схемы стейта под notes/drafts/font_scale — вместе с фичами,
которые их используют (поздние фазы).

## 1. Состояние

- `PersistedState`: новые optional-поля `showInspector: Bool?`,
  `vimMode: Bool?` (обратная совместимость: старый state.json декодится с nil).
  `sbWidth` уже в схеме.
- `AppModel`:
  - `showInspector` (default `false`), `setShowInspector(_:)` + persist;
  - `sbWidth` (default `360`), `setSbWidth(_:)` с клампом `240...600` + persist;
  - `vimMode` (default `false`), `setVimMode(_:)` + persist — инертный флаг,
    поведение vim-режима — поздняя фаза (HANDOFF §7 «may be stubbed»);
  - `Focus` получает case `.inspector`;
  - загрузка всех трёх в `start()`.

## 2. Inspector-панель

- Новый `Sources/covey/Views/InspectorView.swift`: нативный плейсхолдер —
  `ContentUnavailableView`-стиль (иконка + «Inspector» + secondary-подпись
  «Notes and diffs arrive in a later slice»).
- `ContentView.workspace`: третья панель справа, видима при
  `model.showInspector`; ширина `sbWidth`; собственный драг-divider (зеркало
  левого: `sbWidth = total − x`); тап по панели → `setFocus(.inspector)`.
- `StatusBar`: метка фокуса показывает `sessions`/`terminal`/`inspector`.

## 3. Меню

- **Session-меню** (`CommandMenu("Session")`):
  - «Kill Session…» ⌘W → `model.modal = .kill(selected)`; disabled без выбора;
  - «Rename Session…» ⌘⇧R → `model.modal = .rename(selected)`; disabled без
    выбора.
- **⌘W-перехват**: дефолтный File→Close берёт ⌘W раньше кастомного меню
  (AppKit матчит key-equivalent в порядке меню). Решение — локальный
  NSEvent-монитор keyDown (паттерн среза 9): ⌘W при наличии выбранной сессии →
  Kill-шит, событие гасится (`nil`), окно не закрывается. Монитор живёт в
  `ContentView` (`onAppear`/`onDisappear`). Пункт меню остаётся для
  discoverability.
- **View-меню** дополняется:
  - Toggle «Show Inspector» (`showInspector`);
  - «Focus Sessions» ⌘1 / «Focus Terminal» ⌘2 / «Focus Inspector» ⌘3 →
    `setFocus`; ⌘3 disabled при скрытом инспекторе. Полноценный перенос
    first responder — вместе с vim-режимом (поздняя фаза);
  - Toggle «Vim Mode» (`vimMode`, инертный).

## 4. Тесты

- **AppModelChromeTests** (дополнение): `setShowInspector`/`setSbWidth`/
  `setVimMode` персистятся (`store.flush()` + `load()`) и загружаются в
  `start()`; кламп `sbWidth` (239→240, 601→600); `setFocus(.inspector)`.
- **StateStore/PersistedState round-trip**: новые поля переживают
  encode/decode; старый JSON без них декодится (nil).
- Меню, монитор ⌘W, драг divider — смоук (UI-слой).

## 5. Границы

- Не трогаем: демон, IPC, терминал, session list.
- Не делаем: контент инспектора, реальный vim-режим, first-responder-роутинг
  фокуса, font_scale.

## 6. Definition of Done

1. Сборка + полный набор тестов зелёные.
2. Смоук:
   - View→Show Inspector: панель появляется, ширина драгается, перезапуск
     сохраняет ширину и видимость;
   - ⌘W с выбранной сессией — Kill-шит, окно живо; без выбора — no-op;
   - Session-меню: Kill/Rename открывают шиты;
   - ⌘1/⌘2/⌘3 меняют метку фокуса в статус-баре;
   - Vim Mode переживает перезапуск, ни на что не влияет.
