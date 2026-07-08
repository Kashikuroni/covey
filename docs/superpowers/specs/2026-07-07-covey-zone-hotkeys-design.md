# Слайс 30 — ⌘1-5 зоны, space u v сплит, честные заголовки (Design Spec)

> Пять зон получают глобальные ⌘1-5 (через меню View — работают из
> любого фокуса, включая терминал), заголовки зон подписываются
> бейджами `[N]`, сплит инспектора переезжает на `space u v` (мёртвый
> `s`-тогл выпиливается), а в сплит-режиме вместо вводящей в
> заблуждение строки табов каждая панель получает свой заголовок.
> База: ветка `slice-28`.

## 0. Назначение

Переключение зон одной клавишей из любого места (схема lazygit:
⌘1 session, ⌘2 agent, ⌘3 note, ⌘4 issues, ⌘5 terminal), подписи `[N]`
в заголовках — самодокументация. Сплит инспектора управляем и честен
визуально.

## 1. ⌘1-5 через меню View

Существующие пункты Focus Sessions ⌘1 / Focus Terminal ⌘2 /
Focus Inspector ⌘3 заменяются пятью:

| пункт | ⌘ | действие |
|---|---|---|
| Focus Session | ⌘1 | `setFocus(.sessions)` |
| Focus Agent | ⌘2 | пейн агента выбранной сессии |
| Focus Note | ⌘3 | инспектор + таб note |
| Focus Issues | ⌘4 | инспектор + таб issue |
| Focus Terminal | ⌘5 | companion-шелл терминал-сплита |

Механика: menu key equivalents — AppKit отдаёт ⌘ меню раньше вью
(SwiftTerm, поля — не перехватят). Монитор ContentView ⌘ не трогает
(кроме спецкейса ⌘W) — менять его не нужно.

`AppModel.focusZone(_ zone: FocusZone)`, `enum FocusZone { session,
agent, note, issues, terminalSplit }` — вытяжка активационной логики
из `cycleFocus`:

- `.agent` без выбранной сессии → тост `no session`;
- `.note`/`.issues` при скрытом инспекторе → тост
  `inspector hidden — space u i` (авто-показа НЕТ — решение);
- `.issues` — как `selectInspectorTab(.issue)`: экран таба
  (browser/composer) не сбрасывается;
- `.terminalSplit` без companion → тост `no split — space t v / h`.

## 2. space u v — сплит инспектора

- `(.ui, "v") → .inspectorSplitToggle` в KeyRouter (KeyAction уже
  есть); which-key ui-меню: строка `v — inspector tabs / split`.
- Мёртвый маппинг `s` (focus == .inspector → inspectorSplitToggle) из
  KeyRouter удаляется — плейн-клавиши инспектора монитор отдаёт вью,
  до роутера `s` никогда не доезжал. Подсказка `s tabs / split` в
  StatusBar и упоминание в HelpOverlay удаляются/обновляются на
  `space u v`.

## 3. Бейджи зон в заголовках

Суффикс в зонном стиле (font 10 semibold, как сейчас):

- SessionListView: `Session [1]`;
- TerminalPaneView: `Agent [2]`, `Terminal [5]` (заголовки пейнов);
- Инспектор: `Note [3]`, `Issue [4]`.

Цвет заголовка как сейчас (активная зона `tk.accent`, иначе `tk.t4`);
сам `[N]` — всегда `tk.t4`, чтобы не спорить с именем.

## 4. Инспектор: честный сплит

- **tabs-режим** — как сейчас: строка табов `Note [3] · Issue [4]`,
  клик переключает.
- **split-режим** — общий tabsHeader убирается. Каждая панель получает
  свой заголовок-полоску над собой (тот же вид: font 10 semibold, фон
  `tk.surface`, паддинги как у tabsHeader): `Note [3]` над note-панелью,
  `Issue [4]` над issue-панелью. Подсветка — у панели, владеющей
  фокусом (`focus == .inspector && inspectorTab == …`); клик по
  заголовку фокусирует её (как клик по табу сейчас).

## 5. Тесты

- `focusZone`: гарды/тосты через makeModel-харнесс — `.agent` без
  сессии; `.note`/`.issues` при скрытом инспекторе; `.terminalSplit`
  без companion; happy-path `.session` меняет focus.
- KeyRouterTests: `(.ui, "v") → .inspectorSplitToggle`; удалённый
  `s`-маппинг больше не роутится (обновить существующий тест, если
  он его пинит).
- Заголовки/сплит — руками.

## 6. Вне скоупа

- Плейн-цифры 1-9 (answerPrompt в зоне сессий) — не трогаем.
- Авто-создание терминал-сплита по ⌘5, авто-показ инспектора по ⌘3/⌘4.
- Изменение cycleFocus (⌃h/⌃l) — остаётся как есть.
