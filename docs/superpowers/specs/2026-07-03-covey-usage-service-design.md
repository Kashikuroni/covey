# Slice 7 — covey usage service (Design Spec)

> Дата: 2026-07-03
> Источник верхнеуровневого брифа: `HANDOFF.md` (§9 Claude usage limits), ground truth —
> `agents_multiplexer` ветка `feat/desktop-swift`, `crates/amux-core/src/usage.rs`,
> `usage/parse.rs`, `usage/credentials.rs`.
> Это спека **седьмого среза**: Claude usage-лимиты и чип в хедере терминала.
> Декомпозиция финальной GUI-фазы (решение брейнсторма): **срез 7** — UsageService +
> чип (сетевой/keychain-кусок, эта спека); **срез 8** — UI-хрома (topbar counts/часы,
> статус-бар, фильтр, history-mode, drag-reorder, show_* тумблеры).

## 0. Контекст и метод

- Срезы 5–6 дали живой GUI: окно, список Active/Recent, терминал, ситы, персистентность.
- Срез 7 добавляет Claude usage: чтение OAuth-токена, `GET /api/oauth/usage` + `/profile`,
  парсинг окон 5h/7d/7d-sonnet + бейдж плана, чип в хедере терминала для Claude-сессий.
- Метод: TDD для чистых юнитов (парсинг, credentials-JSON, состояние AppModel через
  инъекцию fetcher), сеть/keychain — ручной smoke. Git-операции записи — за пользователем.

## 1. Решения брейнсторма

- **Декомпозиция**: срез 7 — только usage; UI-хрома — срез 8.
- **Keychain через shell `security`** (как в Rust): `security find-generic-password -s
  "Claude Code-credentials" -w` через `Process`. Не требует entitlements/подписи, работает
  без .app-бандла (у нас SwiftPM-executable). Файл `~/.claude/.credentials.json` читается
  первым, keychain — fallback; предпочитается non-expired источник, при равенстве — keychain.
- **HTTP через URLSession** (нативный async), не curl.
- **fetchAccount инъектируется** в AppModel ⇒ поллер и состояние тестируются без сети/keychain.

## 2. Границы среза

### В scope
- `Usage.swift`: модель `Usage`/`UsageWindow`/`Account` + чистые `parseUsage`/`parsePlan`/
  `planLabel` (порт `usage/parse.rs`).
- `Credentials.swift`: `readToken()` (файл + keychain fallback), `credentialsFromJSON`.
- `UsageService.swift`: async `fetchAccount()` через URLSession; `oauthGet(path)`.
- `AppModel`: `usage`/`plan`/`usageError` + usage-поллер (~60с), инъекция fetcher.
- `UsageChip`: чип в хедере `TerminalPaneView`, только для Claude-сессий.

### Отложено (срез 8)
- Topbar (counts/часы/переключатели вида/темы), статус-бар, фильтр сессий, history-mode
  индикатор, drag-reorder (`order`/`project_order`), `show_*` тумблеры.

### Вне фазы
- OAuth refresh (полагаемся на то, что Claude Code сам обновляет токен in-place; при
  протухании API вернёт 401 — показываем код).
- Usage-лог (Rust вёл кольцевой лог запросов) — не портируем, YAGNI.

## 3. Компоненты

```
covey/
  Usage.swift            — НОВОЕ: Usage/UsageWindow/Account; parseUsage/parsePlan/planLabel
  Credentials.swift      — НОВОЕ: readToken(); credentialsFromJSON(_:)
  UsageService.swift     — НОВОЕ: fetchAccount() async; oauthGet(_:) async
  AppModel.swift          — РАСШИРЕНИЕ: usage/plan/usageError; usagePoller; fetcher-инъекция
  Views/UsageChip.swift  — НОВОЕ: чип окон + бейдж плана / ворнинг ошибки
  Views/TerminalPaneView.swift — РАСШИРЕНИЕ: UsageChip в хедере для Claude-сессий
```

Ответственности:
- `Usage` — чистая модель + парсеры; ни сети, ни IO.
- `Credentials` — только добыча токена; знает про файл и `security`, не про HTTP.
- `UsageService` — только сеть: токен → HTTP → `Account`/код ошибки.
- `AppModel` — поллер и хранение снапшота; не знает про парсинг/keychain (только fetcher).
- `UsageChip` — чистое отображение переданного `Account`.

## 4. Модель и парсинг (Usage.swift)

```swift
public struct UsageWindow: Equatable {
    public var utilization: Double     // 0–100
    public var resetHHMM: String?      // локальное HH:MM, если известно
}
public struct Usage: Equatable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var sevenDaySonnet: UsageWindow?
    public var isEmpty: Bool { fiveHour == nil && sevenDay == nil && sevenDaySonnet == nil }
}
public struct Account: Equatable {
    public var usage: Usage?
    public var plan: String?
    public var usageError: String?     // "no auth"/"net"/"401"/"429"/"parse" или nil
}

/// Парсит тело /api/oauth/usage. resetHHMM здесь НЕ форматируется (это делает
/// fetchAccount из resets_at). Все окна null → nil (200 без подписки не показываем).
func parseUsage(_ body: Data) -> Usage?
/// organization.rate_limit_tier → бейдж (e.g. "Max 5×"). nil если поля нет.
func parsePlan(_ body: Data) -> String?
/// slug → короткий бейдж: база (Max/Pro/Team/Enterprise/Claude) + хвост "_Nx" → "N×".
func planLabel(_ tier: String) -> String
```

Семантика 1-в-1 с `parse.rs`: `utilization` из `utilization`; `resets_at` (ISO8601) →
`resetHHMM` при форматировании в `fetchAccount`; all-null → nil.

## 5. Credentials.swift

```swift
struct RawCredentials { var accessToken: String; var expiresAtMs: Int64? }

/// Токен из файла ~/.claude/.credentials.json ИЛИ keychain (`security
/// find-generic-password -s "Claude Code-credentials" -w`). Предпочитает
/// non-expired источник; при обоих валидных — keychain (Claude Code обновляет его
/// in-place). Оба протухли/один есть → всё равно вернуть (пусть API отдаст 401).
func readToken() -> String?

/// Чистый разбор JSON `{"claudeAiOauth":{"accessToken":...,"expiresAt":ms}}`.
func credentialsFromJSON(_ s: String) -> RawCredentials?
```

`expiresAtMs` в миллисекундах Unix (как в Rust). `isExpired` = `expiresAtMs < now_ms`.

## 6. UsageService.swift

```swift
enum UsageService {
    /// Один цикл: usage + plan независимо (частичный успех допустим).
    static func fetchAccount() async -> Account
    /// GET OAuth-эндпоинта с Bearer-токеном. Успех → тело; иначе короткий код:
    /// "no auth" (нет токена), "net" (сбой соединения), "<status>" (не-2xx).
    static func oauthGet(_ path: String) async -> Result<Data, String>
}
```

- `oauthGet`: `readToken()` → nil ⇒ `.failure("no auth")`. Иначе `URLRequest` к
  `https://api.anthropic.com<path>` с точными заголовками Claude Code (из `usage.rs`):
  - `Authorization: Bearer <token>`
  - `anthropic-beta: oauth-2025-04-20`
  - `User-Agent: claude-code/1.0.0` — **обязателен**: без него запрос попадает в жёстко
    лимитированный бакет и стабильно отдаёт 429.
  - `timeoutInterval = 10`.
  Не-2xx → `.failure("\(statusCode)")`; ошибка URLSession → `.failure("net")`.
- `fetchAccount`: `oauthGet("/api/oauth/usage")` → `parseUsage` (+ форматирование
  `resetHHMM` из `resets_at`); `oauthGet("/api/oauth/profile")` → `parsePlan`.
  Ошибка usage → `usageError`; ошибка plan → просто `plan == nil`.

## 7. AppModel (расширение)

- Состояние: `public private(set) var usage: Usage?`, `plan: String?`, `usageError: String?`.
- Инъекция в init: `fetchAccount: () async -> Account` (дефолт продакшена —
  `UsageService.fetchAccount`), `usageInterval: TimeInterval = 60`.
- `start()` запускает `usagePoller` — `Task`: сразу `tickUsage()`, затем цикл
  `sleep(usageInterval)` → `tickUsage()`. `tickUsage` = `let acc = await fetchAccount();
  usage = acc.usage; plan = acc.plan; usageError = acc.usageError`.
- Поллер отменяется в `deinit` и пересоздаётся в `reconnect()` (как eventLoop).
- Поллер не зависит от наличия Claude-сессий (дёшево, 60с); чип решает видимость сам.

## 8. UsageChip и хедер

- `UsageChip(usage:plan:error:)` — чистая вью:
  - есть `usage`: `HStack` окон — `5h 77%`, `7d 40%`, (`S 7d 12%` для sonnet, если есть) +
    бейдж плана. Формат окна — чистый хелпер `windowLabel(prefix:_ w:UsageWindow)->String`.
  - нет usage, есть `error`: маленький ворнинг с кодом.
  - иначе: `EmptyView` (чип скрыт).
- `TerminalPaneView.header`: если agent выбранной сессии содержит "claude"
  (case-insensitive), показать `UsageChip(usage: model.usage, plan: model.plan,
  error: model.usageError)`.

## 9. Тесты

- `UsageParseTests` (порт `parse.rs`): `parseUsage` валидное → окна с utilization; все
  окна null → nil; мусор → nil. `parsePlan`: `default_claude_max_5x`→`Max 5×`,
  `{}`→nil. `planLabel`: max/pro/team/enterprise/unknown, множитель `_5x`→`5×`, без него.
- `CredentialsTests`: `credentialsFromJSON` вытаскивает token + expiresAtMs; битый JSON → nil.
- `AppModelUsageTests` (фейк-fetcher): один тик выставляет usage/plan/usageError; частичный
  `Account` (usage=nil, error="429") — usage nil, error выставлен; изменение фейк-ответа →
  повторный тик обновляет состояние (короткий interval + async-поллинг).
- `UsageChipTests`: `windowLabel` формат; хелпер видимости (agent "claude" vs "sh").
- Живой fetch + keychain + реальный API — ручной smoke (нужны Claude-креды).
- Без сети и thread-`sleep` в тестах.

## 10. Definition of Done

1. Сборка + все тесты зелёные (старые + новые Usage/Credentials/AppModel/Chip).
2. `swift run covey` с активной Claude-сессией и валидными кредами: в хедере терминала —
   чип с окнами 5h/7d и бейджем плана; обновляется в фоне (~60с).
3. Нет кредов / протухли → чип показывает код ошибки ("no auth"/"401"), UI не падает.
4. Не-Claude сессия (`sh`) → чипа нет.
5. Сбой сети/keychain никогда не роняет приложение — только `usageError`.
