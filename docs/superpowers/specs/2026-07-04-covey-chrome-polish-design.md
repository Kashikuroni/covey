# Слайс 21 — полировка хрома: иконки агентов, countdown лимитов, минус кнопка темы (Design Spec)

> Три мелкие правки GUI. Демон и протокол не трогаем — смоук без
> рестарта coveyd.

## 1. Убрать кнопку темы из TopBar

- `TopBar.swift`: удалить `Button` с `sun.max`/`moon` (строки 16–21).
  Часы остаются. Переключение темы — только `space a t` (which-key уже
  показывает пункт).
- Тестов нет (чистое удаление view-кода).

## 2. Обратный отсчёт до сброса лимитов в usage-чипе

Сейчас чип показывает абсолютное время сброса: `5h 77% · 10:40`.
Становится остаток до сброса: `5h 77% · 2h13m`, `7d 40% · 3d4h`.

### Модель и сервис

- `UsageWindow` теряет поле `resetHHMM` — остаётся `utilization` +
  `resetUnix`. Всё считается из `resetUnix` на месте отображения.
- `UsageService.fillResetTimes` удаляется (единственный потребитель
  `resetHHMM`).

### Форматирование (чистая функция в UsageChip.swift)

`func remainingLabel(resetUnix: Int64, now: Date) -> String`:

| Остаток | Формат | Пример |
|---|---|---|
| ≤ 0 | `0m` | `0m` |
| < 1 ч | `Xm` | `37m` |
| < 24 ч | `XhYm`, минуты 0 → `Xh` | `2h13m`, `2h` |
| ≥ 24 ч | `XdYh`, часы 0 → `Xd` | `3d4h`, `3d` |

`windowLabel(prefix:w:now:)` получает параметр `now` и подставляет
`remainingLabel`; без `resetUnix` — как раньше только процент.

### Тикание

- Тело `UsageChip` оборачивается в `TimelineView(.everyMinute)`,
  `ctx.date` передаётся как `now` — отсчёт живёт между 60-секундными
  поллами `fetchAccount` и не зависит от того, изменился ли `Usage`
  (Equatable-равные снапшоты не перерендерили бы чип сами).

### Тесты

- `UsageChipTests`: `remainingLabel` — границы (0/просрочка, 59m, 60m,
  `2h13m`, ровно `2h`, 23h59m, `1d`, `3d4h`); `windowLabel` с/без
  `resetUnix`.
- `UsageParseTests`: убрать ассерты про `resetHHMM`.

## 3. Иконки агентов на карточках сессий

Вместо текста `claude`/`codex` во второй строке карточки — иконка.
Решение пользователя: настоящая иконка Claude.app + векторный логотип
OpenAI для codex.

### Классификатор (новый файл `Sources/covey/Views/AgentIcon.swift`)

```swift
enum AgentKind { case claude, codex, other }
func agentKind(_ agent: String) -> AgentKind  // lowercased().contains
```

- `"claude"`, `"claude-yolo"` → `.claude`; `"codex"` → `.codex`;
  прочее → `.other`.
- Существующий `isClaudeAgent` в UsageChip.swift заменяется на
  `agentKind(...) == .claude` (одна точка классификации).

### AgentIcon view

- `.claude` — `NSImage` из `NSWorkspace.shared.icon(forFile:
  "/Applications/Claude.app")`, взятая один раз в статический кэш;
  перед этим `FileManager.fileExists` — приложения нет → фолбэк на
  текст (текущее поведение).
- `.codex` — логотип OpenAI (шестилепестковый узел) как SwiftUI
  `Path`/`Shape`, залит `tk.t3` — тонируется под обе темы.
- `.other` — `Text(agent)` как сейчас.
- Размер 13×13, у иконки `.help(agent)` — имя агента в тултипе.

### Встраивание

- `SessionListView.card`: оба вхождения `Text(session.agent)` (ветка с
  git-строкой и без) → `AgentIcon`.

### Тесты

- `AgentIconTests`: классификатор (`claude`, `claude-yolo`, `codex`,
  `aider` → other, пустая строка → other); фолбэк-ветка при
  отсутствующем пути (функция выбора источника, вынесенная из view).

## Порядок работ

1. TopBar: минус кнопка темы.
2. Countdown: модель → форматтер → чип → тесты.
3. Иконки: классификатор → view → карточки → тесты.

## Смоук (user)

Рестарт демона НЕ нужен (демон/протокол не менялись).

1. TopBar: кнопки темы нет, часы на месте; `space a t` переключает тему.
2. Usage-чип: `5h NN% · XhYm` / `7d NN% · XdYh`; значение уменьшается
   со временем (подождать минуту).
3. Карточки: claude-сессия — иконка Claude.app; codex-сессия — узел
   OpenAI в цвет темы; тултип с именем агента; неизвестный агент
   (пресет с другим именем) — текст.
