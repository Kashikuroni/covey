# Slice 6 — covey state persistence (Design Spec)

> Дата: 2026-07-02
> Источник верхнеуровневого брифа: `HANDOFF.md` (§6 session list Active/Recent,
> §8 Persistence schema), ground truth схемы — `agents_multiplexer` ветка
> `feat/desktop-swift`, `crates/amux-core/src/state.rs`.
> Это спека **шестого среза**: слой персистентности GUI поверх walking skeleton
> (срез 5). Декомпозиция GUI-фазы: срез 5 — скелет; **срез 6** — персистентность
> (эта спека); срез 7 — usage-чип, topbar, статус-бар, фильтр, ordering, history mode.

## 0. Контекст и метод

- Срез 5 дал живой SwiftUI-скелет: окно, список Active, терминал, ситы New/Kill/Rename.
- Срез 6 добавляет `state.json` (persisted UI-state), Recent-вкладку, тему dark/light,
  сохраняемую ширину сплита.
- Метод: TDD для чистых юнитов (`PersistedState`, `StateStore`, `AppModel`),
  вьюхи — ручной smoke. Git-операции записи — за пользователем.

## 1. Решения брейнсторма

- **JSON без зависимостей** (не TOML): `state.json` читает только `covey`, интеропа со
  старым Rust-приложением нет, руками файл никто не правит. Встроенный `JSONEncoder`/
  `JSONDecoder`, ноль внешних библиотек. Состав полей — как в схеме §8.
- **Полная схема в Codable-структуре**, но живую логику вешаем только на поля с UI
  (тема, ширина сплита, recents). Остальные поля round-trip'ятся, но без потребителя.
- **GUI-only владение**: Active = живой `list` демона; Recent = `state.json` recents.
  `[sessions]` в схеме есть, но НЕ используется (респаун демона — будущий срез).
- Recents наполняются из события `.exited` (kill/сам умер), НЕ из `.sessionRemoved`
  (переименование).

## 2. Границы среза

### В scope (с UI)
- `StateStore`: load/save `~/.covey/state.json`, debounced (0.5 с), атомарная запись.
- Тема dark/light: тумблер, `preferredColorScheme` + палитра терминала.
- Ширина левого сплита: draggable-разделитель, сохраняется/применяется.
- Recent-вкладка: `.exited` → recents; список Recent; relaunch.

### В схеме, без UI (round-trip, но не вешаем логику)
- `order` / `project_order` (drag-reorder — срез 7).
- `show_sessions` / `show_footer` / `show_header` (нет footer/header/topbar — срез 7).
- `notes` / `drafts` / `project_names` / `project_notes` (нет редакторов).
- `[sessions]`, `last_version` (респаун демона / версионирование — будущее).
- `font_scale`, `sb_width` (нет масштаба шрифта / инспектора в скелетоне).

### Отложено целиком
- Респаун сессий демоном после его рестарта (демон-side персистентность).
- Миграции формата (`last_version`).

## 3. Компоненты

```
CoveyKit/
  PersistedState.swift   — НОВОЕ: struct State/PersistedSession/RecentSession (Codable),
                           pushRecent(_:_:), MAX_RECENTS = 20
covey/
  StateStore.swift        — НОВОЕ: load()/save(_:); debounce-таймер; атомарная запись
  Theme.swift             — НОВОЕ: enum Theme (dark/light); TerminalPalette для SwiftTerm
  AppModel.swift          — РАСШИРЕНИЕ: theme, splitPct, recents; StateStore-инъекция;
                            load на старте, save при изменении; pushRecent на .exited; relaunch
  Views/ContentView.swift — РАСШИРЕНИЕ: preferredColorScheme(theme); draggable divider → splitPct
  Views/SessionListView.swift — РАСШИРЕНИЕ: Picker Active/Recent; RecentListView
  TerminalController.swift — РАСШИРЕНИЕ: palette из theme в make/updateNSView
  App.swift               — РАСШИРЕНИЕ: тема-тумблер (тулбар)
```

Ответственности:
- `PersistedState` — чистая Codable-модель + `pushRecent`. Ни IO, ни UI.
- `StateStore` — только файл: load/save/debounce/атомарность. Не знает про сессии.
- `Theme`/`TerminalPalette` — чистые данные палитр.
- `AppModel` — единственный мост события демона ↔ persisted-state ↔ StateStore.

## 4. PersistedState (CoveyKit)

```swift
public struct PersistedSession: Codable, Equatable {
    public var dir: String
    public var agent: String
    public var resumeCmd: String?     // Claude --resume; nil иначе
}

public struct RecentSession: Codable, Equatable {
    public var name: String
    public var dir: String
    public var agent: String
    public var resumeCmd: String?
}

public struct PersistedState: Codable, Equatable {
    // wired this slice
    public var theme: String?         // "dark" | "light"; nil → app default (dark)
    public var splitPct: Int?         // левая панель, % тела; nil → дефолт
    public var recents: [RecentSession]
    // schema-only (round-trip, без UI этот срез)
    public var order: [String]
    public var projectOrder: [String]
    public var projectNames: [String: String]
    public var projectNotes: [String: String]
    public var notes: [String: String]
    public var drafts: [String: String]
    public var sessions: [String: PersistedSession]
    public var fontScale: Int?
    public var sbWidth: Int?
    public var showSessions: Bool?
    public var showFooter: Bool?
    public var showHeader: Bool?
    public var lastVersion: String?

    public init()                     // все коллекции пустые, опционалы nil
}

public let maxRecents = 20

/// Ставит entry в начало recents: удаляет прежнюю с тем же name (перемещение без
/// дублей), затем обрезает до maxRecents. Порт push_recent из state.rs.
public func pushRecent(_ recents: inout [RecentSession], _ entry: RecentSession)
```

Все опционалы кодируются с пропуском nil-значений (компактный файл). Ключи JSON —
чистые Swift-имена (интеропа нет), формат стабилен внутри проекта.

## 5. StateStore (covey)

```swift
public final class StateStore {
    public init(path: String,
                debounce: TimeInterval = 0.5,
                queue: DispatchQueue = DispatchQueue(label: "covey.state"))
    /// Читает и декодирует файл. Нет файла / битый JSON → PersistedState() (дефолт).
    public func load() -> PersistedState
    /// Планирует сохранение через `debounce`; повторные вызовы коалесятся в одну
    /// запись последнего значения. Запись атомарна: temp-файл в той же папке + rename.
    public func save(_ state: PersistedState)
    /// Немедленно пишет ожидающее сохранение (для теста и graceful-выхода).
    public func flush()
}
```

- Каталог `~/.covey/` создаётся при первой записи (как для сокета).
- Атомарность: `JSONEncoder` → `Data` → запись во временный файл `state.json.tmp-<pid>` →
  `FileManager.replaceItemAt` / `rename(2)`. Частичный файл наблюдаться не может.
- Debounce: один `DispatchSourceTimer` на очереди; `save` перезаписывает pending-состояние
  и (пере)взводит таймер на `debounce`. `flush` отменяет таймер и пишет немедленно.
- Тесты инъектируют temp-путь и маленький `debounce`.

## 6. AppModel (расширение)

- Новое состояние: `theme: Theme`, `splitPct: Int`, `recents: [RecentSession]`
  (все `private(set)`, кроме мутаторов ниже). Инъекция `StateStore` в init
  (продакшен — путь `~/.covey/state.json`; тесты — temp).
- `start()`: сперва `store.load()` → применить theme/splitPct/recents, затем как раньше
  `list` + event-loop.
- Мутаторы, каждый пишет `persist()`:
  - `setTheme(_:)`, `setSplitPct(_:)` — из UI.
  - relaunch: `relaunchRecent(_ r: RecentSession)` → `create(dir:agent:name:)`.
- `apply(_:)`:
  - `.exited(name, _)`: взять `Session` из `sessions` ДО удаления → `pushRecent`
    (name/dir/agent) → удалить из sessions → `persist()`. (Только `.exited`, не
    `.sessionRemoved` — переименование не «останавливает» сессию.)
  - при `sessionAdded` активной сессии — убрать её имя из отображаемого Recent
    (Recent прячет активные; сами recents не трогаем).
- `persist()` собирает текущий `PersistedState` (сохраняя нетронутыми schema-only поля,
  прочитанные при load) и зовёт `store.save(...)` (debounced).

## 7. Тема и терминал

- `enum Theme: String { case dark, light }`. `TerminalPalette` для каждой темы:
  dark — bg `#1C1917`, fg `#FAF7F2`, оранжевый курсор (как в срезе 5); light — светлый
  порт `TermTheme`.
- `ContentView`: `.preferredColorScheme(model.theme == .dark ? .dark : .light)`.
- `TerminalRepresentable`: палитра из `model.theme` в `makeNSView`; `updateNSView`
  переустанавливает цвета при смене темы (терминал не ремоунтится по теме).

## 8. Вьюхи

- **ContentView**: свой draggable-divider (GeometryReader + DragGesture) между списком и
  терминалом; ширина = `splitPct` % тела; drag → `model.setSplitPct(...)`. Минимумы панелей.
- **SessionListView**: `Picker` Active/Recent (сегмент). Active — как в срезе 5.
  Recent — `RecentListView`: строки stopped-сессий (newest-first, скрывая активные) с
  кнопкой/двойным кликом Relaunch → `model.relaunchRecent(_)`.
- **App**: тема-тумблер в тулбаре (иконка солнце/луна) → `model.setTheme(...)`.

## 9. Тесты

- `PersistedStateTests`: Codable round-trip полной структуры (включая nil-пропуски);
  `pushRecent` — дедуп по name, newest-first, обрезка до 20.
- `StateStoreTests`: save→flush→load round-trip; N быстрых `save` → один файл-райт
  (счётчик записей через наблюдение mtime/размера или счётчик в подклассе); битый файл →
  дефолт; отсутствующий файл → дефолт; после save виден только целый JSON (нет `.tmp`).
- `AppModelTests` (против TestDaemon + temp StateStore):
  - `.exited` пушит recent с корректными dir/agent; сессия ушла из sessions.
  - rename (sessionRemoved) НЕ пушит recent.
  - `relaunchRecent` зовёт `create` (сессия появляется в Active).
  - `setTheme`/`setSplitPct` → после `store.flush()` файл содержит значение.
  - `start()` на непустом `state.json` применяет theme/splitPct/recents.
- Divider, Picker, палитры, тема-тумблер — ручной smoke.
- Без thread-`sleep` в тестах; debounce проверяется через `flush()` или короткий interval
  + async-поллинг.

## 10. Definition of Done

1. Сборка + все тесты зелёные (старые + новые State/Store/AppModel).
2. `swift run covey`: смена темы применяется мгновенно (UI + терминал) и переживает
   перезапуск приложения.
3. Ширина сплита тянется мышью и восстанавливается после перезапуска.
4. Kill сессии → она появляется в Recent; Relaunch из Recent поднимает её заново.
5. `state.json` — валидный JSON, обновляется не на каждый чих (debounced), пишется
   атомарно (нет битых/частичных файлов).
