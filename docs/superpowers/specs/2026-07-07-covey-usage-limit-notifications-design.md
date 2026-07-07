# Системные уведомления о лимитах usage: 5h / 7d ≥ 80% (Design Spec)

> Covey уже поллит `/api/oauth/usage` раз в 60 секунд и рисует проценты
> в `UsageChip`. Этот слайс добавляет системное macOS-уведомление, когда
> утилизация окна 5h или 7d впервые достигает 80%: какое окно, сколько
> осталось, через сколько восстановится. Одно уведомление на окно —
> следующее только после сброса окна (новый `resets_at`). Окно 7d Sonnet
> не уведомляется.

## 0. Контекст

- `AppModel.tickUsage()` (`/covey/Sources/covey/AppModel.swift`) каждые
  60с кладёт свежий `Usage` в модель. `Usage` (`/covey/Sources/covey/Usage.swift`)
  несёт три окна: `fiveHour`, `sevenDay`, `sevenDaySonnet`; у каждого
  `utilization: Double` (0–100) и `resetUnix: Int64?` из `resets_at`.
- Порог 80% уже существует как граница `usageLevel .err`
  (`/covey/Sources/covey/Views/UsageChip.swift`) — уведомление использует
  ту же константу, конфигурация не нужна (YAGNI).
- `UNUserNotificationCenter` работает только внутри .app-бандла: у голого
  SPM-бинаря и xctest-хоста обращение к центру трапится. День-в-день
  цикл — `swift build` / `swift test`; бандл собирается `make app`.
  Решение: вне бандла уведомления тихо выключены.
- `PersistedState` (`/covey/Sources/CoveyKit/PersistedState.swift`) —
  Codable со всеми новыми полями как optional; старые `state.json`
  продолжают декодиться. Сохранение — `AppModel.persist()`.

## 1. LimitWatch — чистая логика

Новый файл `/covey/Sources/covey/LimitWatch.swift`. Никаких side
effects: вход — снапшот usage и маркеры, выход — алерты и новые маркеры.

```swift
struct LimitAlert: Equatable {
    let windowKey: String    // "5h" | "7d"
    let title: String        // "Claude 5h limit at 82%"
    let body: String         // "18% left · resets in 2h13m"
}

/// notified: windowKey -> resetUnix окна, о котором уже уведомили
/// (0 — уведомили при отсутствующем resets_at).
func limitAlerts(usage: Usage, notified: [String: Int64], now: Date)
    -> (alerts: [LimitAlert], notified: [String: Int64])
```

Правила, по окну (`fiveHour` → "5h", `sevenDay` → "7d"; `sevenDaySonnet`
игнорируется):

- **Триггер:** `utilization >= 80` и маркер окна отсутствует либо
  не равен текущему `resetUnix` → алерт + `notified[key] = resetUnix ?? 0`.
  Условие `>=` покрывает скачок 79→95 между поллами.
- **Дедуп:** маркер равен текущему `resetUnix` → тишина. Окно
  сбросилось → API отдаёт новый `resets_at` → при следующем пересечении
  80% новый алерт.
- **Очистка:** `utilization < 80` → маркер окна удаляется. Это же
  сбрасывает fallback-маркер `0` (случай без `resets_at`).
- Окно отсутствует в `Usage` → маркер не трогаем (обрыв сети не должен
  ронять дедуп текущего окна).

Текст (UI app на английском):

- Title: `Claude 5h limit at 82%` — процент округлён как в чипе
  (`Int(utilization.rounded())`).
- Body: `18% left · resets in 2h13m` — остаток `100 − pct`, хвост через
  существующий `remainingLabel(resetUnix:now:)`. Без `resets_at` — только
  `18% left`.

## 2. Notifier — системная обёртка

Новый файл `/covey/Sources/covey/Notifier.swift`. Тонкая обёртка над
`UNUserNotificationCenter`, вся бандловая специфика в одном месте:

```swift
enum Notifier {
    /// false вне .app-бандла (голый SPM-бинарь, xctest-хост `swift test`) —
    /// все методы тогда no-op. Проверка по bundleIdentifier не годится:
    /// у xctest он есть, а UNUserNotificationCenter всё равно трапится.
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    static func requestPermission()       // .alert + .sound, fire-and-forget
    static func post(_ alert: LimitAlert) // UNMutableNotificationContent, немедленно
}
```

- `requestPermission()` вызывается один раз при старте app (после
  создания модели). Отказ пользователя не обрабатываем: `post` при
  отсутствии разрешения молча уходит в никуда — приемлемо.
- `post` шлёт запрос с `UNNotificationRequest(identifier: UUID)`,
  без категорий и кастомных действий: клик по уведомлению делает
  дефолт (активирует app), этого достаточно.
- **Foreground-показ (ревизия после финального ревью):** без делегата
  macOS глушит баннеры приложения на переднем плане — а главный
  сценарий именно такой (пользователь работает в Covey, когда окно
  пересекает 80%). Notifier держит статический
  `UNUserNotificationCenterDelegate` (`delegate` у центра weak), чей
  `willPresent` возвращает `[.banner, .sound]`; делегат ставится в
  `requestPermission()` за тем же гардом `available`. Без этого
  заглушённый алерт терялся бы на весь цикл окна — маркер к тому
  моменту уже записан.
- Юнитами не кроется — тонкий системный враппер.

## 3. Wiring и персист

- `PersistedState` + новое поле `usageNotified: [String: Int64]?`
  (optional → обратная совместимость старых `state.json`).
- `AppModel.tickUsage()` после обновления `usage`:

  ```
  guard let usage = acc.usage else { return }        // сеть/парс упали — маркеры не трогаем
  let (alerts, marks) = limitAlerts(usage:notified:now:)
  alerts.forEach(Notifier.post)
  if marks != старых { persisted.usageNotified = marks; persist() }
  ```

- Рестарт app внутри того же окна повтора не даёт: маркер приехал из
  `state.json`.
- Оба окна пересекли порог за один тик → два уведомления, это ок.

## 4. Тесты

TDD по чистой `limitAlerts`
(`/covey/Tests/CoveyAppTests/LimitWatchTests.swift`), сценарии:

1. Пересечение: util 82, маркера нет → один алерт, маркер = resetUnix.
2. Дедуп: тот же снапшот повторно → пусто.
3. Новый цикл: util 82, маркер от старого resetUnix → новый алерт.
4. Очистка: util 30 при существующем маркере → маркер удалён.
5. Без `resets_at`: алерт с маркером 0, body без хвоста reset;
   повтор — тишина; util < 80 — маркер снят.
6. Sonnet: util 99 в `sevenDaySonnet` → тишина.
7. Оба окна ≥ 80 разом → два алерта.
8. Окно пропало из Usage → маркер сохраняется.
9. Текст: title/body с процентом, остатком и `remainingLabel`-хвостом.

Ручная проверка: `make install`, дождаться реального ≥80% (или временно
опустить порог в ветке) — уведомление приходит, клик активирует Covey,
повторов в течение окна нет.

## 5. Вне скоупа

- Конфигурируемый порог, повторные пороги (90/100%).
- Уведомления при закрытом GUI (daemon-side вотчер).
- Окно 7d Sonnet.
- osascript-фолбэк для dev-бинаря.
