# Slice 10 — реестр демона: персист + lost→Recent (Design Spec)

> Дата: 2026-07-02
> Источник: HANDOFF §4 (restart semantics), §8 (владение реестром), §12 DoD п.1 —
> с согласованными отклонениями (см. §4 ниже). Память: `handoff-is-sketch-not-gospel`.

## 0. Контекст и проблема

Сейчас `coveyd` держит реестр сессий только в памяти: после рестарта демона или
ребута сессии исчезают бесследно. GUI-события (`exited`/`sessionRemoved`) при
смерти демона не приходят, поэтому пропавшие сессии не попадают и в Recent —
пользователь теряет список того, что у него работало.

## 1. RegistryStore (CoveydCore, новый файл)

JSON-файл `~/.covey/registry.json` (путь инжектится конструктором — тесты
используют temp). Содержимое: массив

```swift
public struct SessionMeta: Codable, Equatable {
    public var name: String
    public var dir: String
    public var agent: String
    public var argv: [String]
    public var created: Int64
}
```

API: `load() -> [SessionMeta]` (повреждённый/отсутствующий файл → `[]`),
`save(_ metas: [SessionMeta])` — синхронная атомарная запись (файл крошечный,
вызывается с очереди/лока демона; дебаунс не нужен).

Владение разведено по HANDOFF §8: `registry.json` — демона, `state.json`
(recents и пр.) — GUI.

## 2. SessionRegistry — персист + lost

- `init(clock:persisted:onPersist:)` — новые параметры со значениями по
  умолчанию (`persisted: []`, `onPersist: nil`) — существующие вызовы не
  ломаются.
- Записи `persisted` прошлой жизни демона становятся `lost: [SessionMeta]`
  (процессы НЕ спавнятся).
- После каждой мутации живого набора (`create` успешен, `handleExit`,
  `rename`) — `onPersist(snapshotMeta())`, где `snapshotMeta()` — метаданные
  живых сессий.
- `lost` (чтение) и `clearLost()` — под тем же локом.

## 3. Протокол и IPC

- `ServerMessage.Result.sessions` дополняется полем `lost: [Session]?`
  (optional Codable — обратная совместимость; `SessionMeta` конвертируется в
  `Session` с `git/worktreeRepo = nil`).
- Новый `Request.Op.clearLost` → `.ok`. `IPCServer.dispatch` зовёт
  `registry.clearLost()`.
- `IPCClient.list()` возвращает `(sessions, statuses, lost)`;
  `IPCClient.clearLost()`.
- `coveyd/main.swift` и `TestDaemon`: создают `RegistryStore`, передают
  `persisted: store.load()`, `onPersist: store.save`.

## 4. GUI (AppModel)

В `start()` после успешного `list`: если `lost` непуст — для каждой
`pushRecent(&recents, RecentSession(name:dir:agent:))` (существующий дедуп и
кап 20), затем `persist()` и `try? await client.clearLost()`. Новых view нет —
Recent-таб уже рендерит и перезапускает.

## 5. Отклонения от HANDOFF (согласованы 2026-07-02)

- **Без авто-respawn** при старте демона: свежий агент всё равно теряет
  контекст разговора, но начал бы работать и тратить токены без присмотра.
  Потерянные сессии возвращаются одним кликом из Recent.
- **LaunchAgent отложен** до появления .app-бандла: plist на dev-бинарь в
  `.build/` хрупок, `KeepAlive` дерётся с отладочными `pkill`; автостарт из
  GUI покрывает текущий сценарий.
- Формат — JSON, не TOML (прецедент `state.json`).

## 6. Тесты

- **RegistryStoreTests** (CoveydCoreTests): round-trip save/load; отсутствующий
  файл → `[]`; мусор в файле → `[]`.
- **SessionRegistryTests**: create/rename/exit дёргают `onPersist` с
  актуальными метаданными; `init(persisted:)` → `lost` совпадает и не
  спавнит; `clearLost()` очищает.
- **IPC (CoveydCoreTests или CoveyKitTests по месту существующих)**: `list`
  несёт `lost`; после `clearLost` повторный `list` — без lost.
- **«Рестарт демона»**: два SessionRegistry подряд на одном RegistryStore —
  у второго `lost` = живые сессии первого.
- **AppModelTests/Chrome**: `start()` с демоном, у которого есть lost →
  recents пополнены (дедуп работает), `store.load().recents` содержит их,
  повторный `start()` (после clearLost) не дублирует.
- Полный набор — 0 падений.

## 7. Границы

- Не трогаем: PTY-слой, статусы, UI-виды, `state.json`-схему (кроме содержимого
  recents), NewSessionSheet.
- `argv` персистится в реестре для точности будущего relaunch, но
  `RecentSession`/relaunch-путь GUI не расширяем в этом срезе.

## 8. Definition of Done

1. Сборка + полный набор тестов зелёные (включая новые Registry/lost-тесты).
2. Смоук: создать 2 сессии → `pkill coveyd` → перезапуск covey → обе сессии в
   Recent, relaunch работает; повторный перезапуск GUI — дублей в Recent нет.
3. `~/.covey/registry.json` отражает живые сессии (create/kill/rename).
