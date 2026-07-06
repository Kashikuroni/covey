# Слайс 25 — предложение рестарта агентов при смене темы (Design Spec)

> Тема не доставляется в процесс claude (нет env/конфига): `installColors`
> перекрашивает только 16 ANSI-слотов живого вью, а claude выбирает палитру
> один раз при старте и эмитит truecolor. Живой агент «застревает» в старой
> теме; единственный способ перекрасить — рестарт. Механика рестарта одного
> агента уже есть end-to-end (`space s u` → `RestartSheet` → IPC
> `restart(name,dir)` → `SessionRegistry.restart/respawn`, claude резюмит
> через `claude --resume <uuid> || claude --session-id <uuid>`). Слайс:
> после тогла темы предложить одной модалкой рестарт idle-агентов + фикс
> демона, чтобы рестарт не убивал companion shell.

## 1. Фикс демона: restart сохраняет companion

Сейчас `SessionRegistry.restart(name:)` зовёт `kill(name:)`, который
сначала валит companion (`SessionRegistry.swift:123-129`), а respawn
воскрешает только родителя — сплит схлопывается навсегда.

- `restart(name:dir:)` после установки `pendingRestart[name]` убивает
  **только родительский PTY**: `withEntry(name)?.process.kill()` вместо
  `kill(name:)`.
- Companion не трогаем: его entry, PTY и связь `companionOf` остаются
  валидными — имя, entry и screen родителя переживают respawn.
- `IPCServer.onRestarted` без изменений: ре-биндит output-fanout родителя
  и шлёт `sessionAdded`-upsert; companion в событиях не участвует.
- Обычный `kill`-op не меняется: там companion гибнет вместе с родителем,
  как и раньше.
- Шеллу рестарт для темы не нужен: его цвета — 16 ANSI-слотов, они
  перекрашиваются вживую через `installColors`.

Фикс распространяется на все пути рестарта: `space s u`, `space a u`,
return-to-root и новый theme-flow.

## 2. Чистая логика: `themeRestartPlan`

По образцу `Lifecycle.confirmsRestart` — чистая функция без зависимостей
(размещение: `Lifecycle.swift`):

```swift
/// Splits live claude sessions into restartable (idle) and kept (busy).
/// Companions and terminal sessions are excluded by the caller's
/// visibleSessions + claude filter.
static func themeRestartPlan(
    sessions: [Session], statuses: [String: Status]
) -> (idle: [String], busy: [String])
```

- Фильтр claude: `agent.split(separator: " ").first == "claude"` — тот же,
  что в `restartAllClaude` (`AppModel.swift:238-244`).
- `statuses[name] == .idle` → idle; `.running`, `.waiting` и **отсутствие
  статуса** → busy (консервативно: waiting держит неотвеченный
  permission-промпт, рестарт его потеряет).
- Вход — `visibleSessions` (companion-шеллы уже отфильтрованы).

## 3. AppModel: триггер и подтверждение

- `setTheme(_:)` остаётся чистым (guard + persist). Загрузка persisted-темы
  при старте модалку не триггерит.
- Диспатч `.toggleTheme` (`AppModel.swift:629-631`): после `setTheme(...)`
  вызывает новый `offerThemeRestart()`:
  - `plan = themeRestartPlan(sessions: visibleSessions, statuses: statusByName)`;
  - `plan.idle` непуст → `modal = .themeRestart`;
  - idle пуст, `plan.busy` непуст → toast
    `"\(busy.count) agent(s) keep old theme — restart when idle (space s u)"`;
  - claude-агентов нет → ничего.
- Confirm → `restartIdleClaude() async -> [String]`: **пересчитывает** план
  в момент подтверждения (кто успел стать busy — молча пропускается), цикл
  по существующему `restart(name:)`, ошибки собираются построчно как в
  `restartAllClaude`.

## 4. UI: `ThemeRestartSheet`

- Новый кейс `Modal.themeRestart` — без payload: списки считаются вживую
  при рендере и заново при confirm.
- Регистрация: `Modal` enum (`AppModel.swift:12-24`), `Modal.id`
  (`Sheets.swift:5-21`), switch в `ContentView.swift:30-48`
  (`.presentationBackground(tokens.surface)` как у остальных).
- Вёрстка по образцу `RestartSheet` (`Sheets.swift:287-316`):
  - заголовок «Apply theme to agents?»;
  - группа «will restart» — idle поимённо;
  - группа «keep old theme» — busy поимённо с пометкой статуса
    (running/waiting);
  - инлайн-ошибки построчно (паттерн `RestartAllSheet`);
  - кнопки Cancel / «Restart N» (`.glassProminent`,
    `.keyboardShortcut(.defaultAction)`).
- Текст-конфирма «yes» нет: рестартуем только idle, операция дешёвая
  (у `RestartAllSheet` конфирм остаётся — он трогает и busy).
- Новых чордов нет: единственный триггер — смена темы (`space a t`).
  Гейт клавиш при открытом sheet уже есть (`KeyRouter.swift:96-97`).

## 5. Эдж-кейсы

- Нет статуса в `statusByName` (гонка со StatusMonitor на старте) → busy,
  не рестартуем.
- Агент стал busy между открытием модалки и confirm → пересчёт при
  confirm, молча пропускаем; ошибок не показываем.
- Ошибка рестарта (dir пропал и т.п.) → строка в инлайн-баннере, sheet
  остаётся открытым.
- Повторный тогл темы при открытой модалке невозможен — sheet гейтит
  клавиши; после Cancel тогл предложит модалку заново.
- Terminal-сессии и companion-шеллы в списки не попадают.

## 6. Тесты (TDD: скелет → тест → реализация)

- **CoveydCore, registry**: рестарт родителя с живым companion →
  companion-процесс жив и остаётся в реестре, у родителя новый PTY,
  `sessionRemoved` для companion не шлётся.
- **Чистая логика** (`themeRestartPlan`): фильтр claude (sh/terminal
  мимо); waiting → busy; нет статуса → busy; idle → idle; пустой вход →
  пустой план.
- **AppModel** (`AppModelChromeTests`): `offerThemeRestart` — есть idle →
  `modal == .themeRestart`; только busy → toast, модалки нет; нет claude →
  ни модалки, ни тоста; `.toggleTheme` меняет тему и зовёт предложение.

## Вне скоупа

- Очередь авто-рестарта для busy-агентов (рестарт «когда освободится»).
- Отложенные по-агентные модалки при переходе в idle.
- Прокидывание темы в claude через env/конфиг.
- Изменения `RestartAllSheet` / `space a u`.
