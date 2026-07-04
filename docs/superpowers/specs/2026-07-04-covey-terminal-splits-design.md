# Слайс 22 — терминальные сплиты: компаньон-шелл (Design Spec)

> Цель: одним чордом открыть чистый шелл (для nvim/lazygit/руками)
> рядом с терминалом выбранной сессии — вертикальным или горизонтальным
> сплитом. Решения пользователя: модель «компаньон-шелл» (один сплит,
> привязан к выбранной сессии), PTY у демона как скрытая сессия,
> клавиши `space t v/h/x` + `⌃\` тогл фокуса панелей.

## 1. Модель и протокол

- `Session.companionOf: String?` — имя родительской сессии; nil =
  обычная. Optional+Codable: старые state.json и клиенты совместимы.
- `Op.create` получает `companionOf: String?` (additive).
- Имя компаньона: `<parent>+sh`. Одна сессия — максимум один компаньон
  (create с занятым именем → ошибка демона; GUI до этого не доводит —
  гард «уже есть» просто фокусирует его).
- Команда компаньона: существующий terminal-путь create
  (`terminal: true` → login-shell), cwd = dir родителя (для
  worktree-сессии — сам worktree).

## 2. Демон (CoveydCore)

- `SessionRegistry.create` принимает и хранит `companionOf`.
- Каскад: `kill(parent)` (включая removeWorktree) и `promote(parent)`
  сначала убивают компаньона (SIGHUP-эскалация как у всех), затем
  родителя/worktree. Порядок важен: шелл живёт внутри worktree.
- `rename(parent)` обновляет `companionOf` у его компаньона и
  переименовывает сам компаньон в `<newName>+sh`.
- `restart(parent)` компаньона НЕ трогает.
- Персист: компаньоны сохраняются в state демона как обычные сессии
  (переживают рестарт GUI). При рестарте ДЕМОНА в lost→Recent
  компаньоны НЕ попадают (мертвый шелл не ресьюмится) — фильтр в
  persistNow/lost-логике.
- StatusMonitor/GitMonitor: без изменений (компаньоны мониторятся, GUI
  их карточек всё равно не показывает).

## 3. GUI: вывод, ввод, фокус (AppModel)

Сейчас: один sink `onTerminalOutput` + `outputBuffer`, события
фильтруются `name == selected`; `sendInput`/`resize` шлют в `selected`.
Сплит требует двух живых терминалов:

- **Sinks по имени**: `onTerminalOutput: [String: ([UInt8]) -> Void]`,
  `outputBuffer: [String: [UInt8]]`. `.output(name,…)` кладёт в sink
  или буфер своего имени. TerminalRepresentable регистрирует sink на
  имя СВОЕЙ сессии (Coordinator хранит name), не на selected.
- **Ввод/resize по имени**: `sendInput(_:to name:)`,
  `resize(cols:rows:name:)` — Coordinator передаёт своё имя.
- **Фокус панели**: `focusedPane: String?` — имя сессии, чей терминал
  получает клавиатуру, когда `focus == .terminal`. Без сплита всегда
  selected; `⌃\` переключает selected ↔ companion.
- **Attach**: при видимом сплите attach на обе сессии
  (`attach(name:sinceSeq:)` уже пер-сессионный, события несут имя);
  смена selected — detach обеих старых, attach новых (+компаньон, если
  есть). Backfill через sinceSeq работает как раньше.
- **Действия**: `.splitVertical` / `.splitHorizontal` —
  гарды: нет selected → toast «no session»; компаньон уже есть → только
  фокус в него; иначе create(dir: parent.dir, terminal: true,
  companionOf: parent.name) и после `sessionAdded` — attach + фокус в
  компаньон. `.splitClose` — kill компаньона. `.splitFocusToggle` —
  тогл `focusedPane` (без сплита — no-op).
- **Закрытие**: `sessionRemoved`/`exited` компаньона (exit в шелле,
  каскад от kill родителя) → сплит схлопывается, `focusedPane` =
  selected. Тост не нужен.
- **Rename при открытом сплите**: демон переименовывает обе сессии
  (§2) — GUI после rename выбранной сессии пере-attach'ит обе панели
  под новыми именами (detach старых имён, attach новых, sinceSeq
  сохраняет хвост) и переносит `splitAxes`-запись на новое имя.
- **Ось**: `PersistedState.splitAxes: [String: String]?`
  (parent → "v"/"h"), выставляется при открытии, живёт после рестарта
  GUI: если у selected есть живой компаньон — сплит поднимается сам с
  сохранённой осью (дефолт "v" при отсутствии записи).

## 4. GUI: вид (TerminalPaneView)

- Если у selected есть компаньон: H/VStack по оси, две
  `TerminalRepresentable` (`.id(name)` каждой), между ними
  перетаскиваемый разделитель (паттерн divider из ContentView), 50/50
  по умолчанию, доля НЕ персистится (YAGNI).
- Сфокусированная панель — рамка `tk.accent` (1pt strokeBorder),
  несфокусированная — `tk.bd`.
- Клик по панели — фокус в неё (mouse-monitor глотания первого клика
  уже есть — расширить: onFocusClick сообщает имя панели).
- Хедер панели один, родительский (компаньону хедер не нужен — экономия
  вертикали).

## 5. Карточки и счётчики

Компаньоны невидимы во всех списках GUI: `orderedSessions`,
`visibleSessionNames` (номера/джампы 1-9), фильтр `/`, `model.counts`,
`restartAllClaude` (шелл и так не claude). Единая точка: computed
`visibleSessions = sessions.filter { $0.companionOf == nil }` и все
перечисленные места ходят через неё.

## 6. Клавиши

- Which-key root: новая группа `t` — «terminal — split v · split h ·
  close split».
- `space t v` → `.splitVertical`, `space t h` → `.splitHorizontal`,
  `space t x` → `.splitClose`.
- `⌃\` → `.splitFocusToggle`: и в terminal-фокусе (ветка router'а до
  форварда байтов, рядом с `⌃q`), и в normal (no-op без сплита).
  ЙЦУКЕН-латинизация не нужна («\» — физическая клавиша).

## 7. Тесты

- ProtocolTests: round-trip `create(companionOf:)`, `Session.companionOf`.
- SessionRegistryTests: create companion (имя, поле), каскадный kill
  parent→companion, rename обновляет пару, lost-фильтр компаньонов.
- IPCServerTests: promote убивает компаньона до снятия worktree
  (порядок через факт успешного promote с живым шеллом в worktree).
- AppModel (KeyRouter/Chrome): гарды split-действий (нет сессии, повтор
  → фокус), `sessionRemoved` компаньона схлопывает сплит и возвращает
  фокус, counts/visibleSessionNames не видят компаньонов, ось
  персистится в StateStore.
- KeyRouterTests: `space t v/h/x` роуты, `⌃\` в terminal- и
  normal-контексте.

## 8. Смоук (user)

ОБЯЗАТЕЛЬНО: `pkill -f coveyd; rm -f ~/.covey/coveyd.sock` (протокол
менялся), затем `swift run covey`.

1. Выбрать claude-сессию → `space t v` — справа открылся шелл в dir
   сессии (для worktree — в worktree), фокус в нём; `lazygit`
   запускается и рисуется корректно.
2. `⌃\` — фокус прыгает между агентом и шеллом (рамка подсвечивает),
   ввод уходит в сфокусированную панель; из nvim `⌃\` тоже работает.
3. `exit` в шелле — сплит схлопнулся, фокус в агенте.
4. `space t h` — горизонтальный сплит; перезапуск GUI — сплит
   поднимается сам с той же осью.
5. Карточек компаньона нет, счётчики/1-9 его не видят.
6. `d` (kill) родителя с открытым сплитом — умирают оба, карточка одна.
7. Перетаскивание разделителя мышью работает; клик по панели фокусирует
   её.
