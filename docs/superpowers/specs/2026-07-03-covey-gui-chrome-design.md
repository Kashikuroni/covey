# Slice 8 — covey GUI chrome (Design Spec)

> Дата: 2026-07-03
> Источник верхнеуровневого брифа: `HANDOFF.md` (§6 UI surfaces — topbar/session-list/
> status-bar, §7 AppModel state machine — Focus/filter/historyMode/show_*).
> Это спека **восьмого среза** — финальная GUI-хрома поверх готового приложения
> (срезы 5–7: скелет, персистентность, usage). Завершает GUI-фазу HANDOFF.

## 0. Контекст и метод

- Срезы 5–7 дали: окно, список Active/Recent, терминал, ситы, персистентность
  (`state.json`), тему, split, usage-чип.
- Срез 8 добавляет chrome: topbar (counts/часы/тема/view-switcher), статус-бар
  (key-hints/history/focus), фуззи-фильтр, history-mode индикатор, drag-reorder
  (order/project_order), show_* тумблеры.
- Метод: TDD для чистых юнитов (`fuzzyMatch`, AppModel counts/order/флаги через
  инъекцию StateStore), вьюхи — ручной smoke. Git-операции записи — за пользователем.

## 1. Решения брейнсторма

- **Один срез** (~6 задач); всё view-слой + состояние AppModel, без новых модулей/зависимостей.
- **View-switcher — заглушка-контрол**: сегмент Standard/Git в topbar, Git disabled/no-op
  (как в HANDOFF: «keep control, stub target»).
- **Drag-reorder**: сессии внутри dir-секции → `order`; порядок dir-секций → `project_order`.
  Оба уже в схеме `PersistedState` (срез 6), теперь применяются и персистятся.

## 2. Границы среза

### В scope
- TopBar: имя, counts (total/running/waiting), view-switcher (Git disabled), тема-тумблер
  (переезжает сюда из App-тулбара), часы `HH:mm`.
- StatusBar: key-hints (`⌘N` new, `⌘F` filter), `HISTORY`-индикатор, активная панель.
- Фуззи-фильтр над списком Active (`⌘F` фокусит), `fuzzyMatch` (subsequence).
- History-mode: делегат `scrolled` терминала → `historyMode`; сброс при смене сессии.
- Focus: `.sessions`/`.terminal`, best-effort по `onTapGesture`.
- Drag-reorder сессий и секций (persist `order`/`project_order`).
- show_* тумблеры (меню View): `showSessions`/`showFooter`/`showHeader` (persist).
- Команды меню: `⌘N` (New), `⌘F` (focus filter).

### Отложено / вне фазы
- Реальная git-вьюха (заглушка навсегда в этой фазе).
- Vim/leader-мод и полный набор ⌘-шорткатов (`keys.rs`) — YAGNI.
- Инспектор (`sb_width`, панель Note/Diff) — вне GUI-фазы.
- Полноценный `@FocusState`-трекинг фокуса — best-effort по тапу этого среза.
- `font_scale` UI — нет потребителя.

## 3. Компоненты

```
covey/
  Fuzzy.swift             — НОВОЕ: fuzzyMatch(_ pattern: String, _ text: String) -> Bool
  AppModel.swift          — РАСШИРЕНИЕ: состояние + мутаторы + counts + orderedSessions
  Views/TopBar.swift      — НОВОЕ
  Views/StatusBar.swift   — НОВОЕ
  Views/SessionListView.swift — РАСШИРЕНИЕ: фильтр-бар, onMove, порядок из order
  Views/ContentView.swift — РАСШИРЕНИЕ: TopBar/StatusBar, скрытие панелей по show_*, focus-тапы
  TerminalController.swift — РАСШИРЕНИЕ: scrolled → setHistoryMode
  App.swift               — РАСШИРЕНИЕ: .commands (⌘N/⌘F); тема-тумблер удаляется из тулбара
```

Ответственности:
- `Fuzzy` — чистый матчер; ни UI, ни состояния.
- `AppModel` — вся логика (порядок, счётчики, фильтр-строка, флаги, history/focus).
- `TopBar`/`StatusBar` — чистые презентационные вьюхи от состояния модели.
- `SessionListView` — фильтрация + reorder-жесты, порядок берёт у модели.

## 4. AppModel (расширение)

```swift
public enum Focus { case sessions, terminal }

// новое состояние
public private(set) var order: [String] = []          // имена сессий в пользовательском порядке (в рамках dir)
public private(set) var projectOrder: [String] = []   // порядок dir-секций
public var filter: String = ""                        // не персистится
public private(set) var historyMode = false
public private(set) var focus: Focus = .terminal
public private(set) var showSessions = true
public private(set) var showFooter = true
public private(set) var showHeader = true

// вычисления
public var counts: (total: Int, running: Int, waiting: Int)
/// dir-секции в порядке projectOrder (неизвестные — в конец, стабильно), внутри —
/// сессии в порядке order (неизвестные — по created).
public func orderedSessions() -> [(dir: String, sessions: [Session])]

// мутаторы
public func setFilter(_ s: String)                    // без persist
public func setHistoryMode(_ on: Bool)                // без persist
public func setFocus(_ f: Focus)                      // без persist
public func moveSession(inDir dir: String, from: IndexSet, to: Int)   // persist order
public func moveProject(from: IndexSet, to: Int)                      // persist projectOrder
public func setShowSessions(_ on: Bool)               // persist
public func setShowFooter(_ on: Bool)                 // persist
public func setShowHeader(_ on: Bool)                 // persist
```

- `start()` при load дополнительно применяет `order`/`projectOrder`/`show_*` из
  `persisted` (theme/split/recents уже применяются).
- `persist()` дополнительно пишет `order`/`projectOrder`/`show_*` в `persisted` (schema-only
  поля по-прежнему не затираются — они читаются при load).
- `moveSession`/`moveProject` обновляют массивы так, чтобы новый порядок закрепился:
  для сессий — переставить имена внутри списка dir и записать полный порядок в `order`;
  для секций — переставить dir'ы в `projectOrder`.
- Смена `selected` (в `select`) сбрасывает `historyMode = false`.
- `counts`: `total = sessions.count`; `running`/`waiting` — по `statusByName`.

## 5. Fuzzy.swift

```swift
/// Subsequence-матч, case-insensitive: символы pattern встречаются в text по порядку
/// (не обязательно подряд). Пустой pattern → true.
func fuzzyMatch(_ pattern: String, _ text: String) -> Bool
```

## 6. TopBar

- `HStack`: `covey` (имя) · counts (`N · ▶R · ⏸W`) · Spacer · сегмент Standard|Git
  (Git `.disabled(true)`) · тема-тумблер (солнце/луна → `model.setTheme`) · часы
  (`TimelineView(.periodic(from: .now, by: 60))` → `Date.now`, формат `HH:mm`).
- Рисуется в `ContentView` над рабочей областью, если `model.showHeader`.

## 7. StatusBar

- `HStack`: key-hints (`⌘N new · ⌘F filter`) · Spacer · `HISTORY` (если `historyMode`,
  жёлтым) · активная панель (`sessions`/`terminal`).
- Рисуется под рабочей областью, если `model.showFooter`.

## 8. Список, фильтр, reorder

- Над Active-списком — `TextField` фильтра с `@FocusState`; `⌘F` ставит фокус.
- Active-список строится из `model.orderedSessions()`, отфильтрованных
  `fuzzyMatch(model.filter, session.name)` (пустой фильтр → все).
- `.onMove` внутри секции → `model.moveSession(inDir:from:to:)`.
- Порядок секций: `.onMove` на уровне секций → `model.moveProject(from:to:)`.
  (Reorder жесты работают, когда фильтр пуст; при активном фильтре список — только чтение.)
- Recent-вкладка без изменений (срез 6).

## 9. Терминал, focus, show_*

- `TerminalController.Coordinator.scrolled(source:position:)` →
  `Task { @MainActor in model.setHistoryMode(position < 0.999) }` (1.0 = низ/лайв).
- `ContentView`: `onTapGesture` на панели списка → `setFocus(.sessions)`, на терминале →
  `setFocus(.terminal)`.
- Меню View (`.commands`): тумблеры `showSessions`/`showFooter`/`showHeader`.
  `showSessions=false` → скрыть левую панель+divider; `showHeader/showFooter` → скрыть
  TopBar/StatusBar.

## 10. Тесты

- `FuzzyTests`: `fuzzyMatch("cl","claude")`=true; `("cx","claude")`=false; `("","x")`=true;
  case-insensitive (`("CL","claude")`=true); порядок важен (`("dc","claude")`=false).
- `AppModelChromeTests` (TestDaemon + temp StateStore):
  - `counts` считает running/waiting/total по statusByName;
  - `orderedSessions` уважает order/projectOrder; неизвестные сессии — по created, неизвестные
    dir — в конец;
  - `moveSession`/`moveProject` → массивы обновлены и записаны (flush→load содержит порядок);
  - `setShowSessions/Footer/Header` персистятся; `start()` на seed-файле применяет их +
    order/projectOrder;
  - `setHistoryMode`/`setFocus`/`setFilter` меняют состояние; `select(other)` сбрасывает
    `historyMode`.
- Вьюхи (TopBar/StatusBar/фильтр-бар/drag/часы/тумблеры) — ручной smoke.
- Без сети и thread-`sleep`.

## 11. Definition of Done

1. Сборка + все тесты зелёные (старые + Fuzzy/AppModelChrome).
2. TopBar: counts обновляются вживую, часы идут, тема-тумблер работает, Git-сегмент виден но
   неактивен.
3. StatusBar: `HISTORY` появляется при прокрутке терминала вверх и гаснет у низа; показывает
   активную панель.
4. Фильтр сужает список по фуззи; `⌘F` фокусит поле; `⌘N` открывает New.
5. Drag-reorder сессий и секций сохраняется и восстанавливается после перезапуска.
6. Тумблеры View скрывают/показывают панель списка, topbar, статус-бар; состояние переживает
   перезапуск.
