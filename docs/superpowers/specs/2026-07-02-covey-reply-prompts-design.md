# Slice 14 — ответы 1-9 на промпты, ⇧Tab (Design Spec)

> **ИЗМЕНЕНИЕ В ХОДЕ СРЕЗА (2026-07-02):** reply-композер (`i`) и драфты
> УДАЛЕНЫ решением пользователя — терминал covey живой, ответ = смена фокуса
> (Enter/⌃Q); композер был костылём неинтерактивного превью TUI. Память:
> `no-reply-composer`. Разделы про `i`/драфты ниже — исторические, не
> реализованы; реализовано: promptChanged, `1-9`, кнопки на карточках, `⇧Tab`.

> Дата: 2026-07-02
> Источник: порт TUI — `ReplyForm`/`handle_reply_key` (app.rs:2073),
> `SendChoice`/`SendText` (main.rs:735, tmux.rs:419-434: choice = digit+Enter,
> text = literal+Enter), драфты (`save_draft` app.rs:2061, отправка удаляет),
> кнопки вариантов на карточке (sessions.rs line 3), `Shift+Tab` → агент.
> `parsePrompt` уже портирован (StatusInference), опции пока выбрасываются.

## 0. Контекст

Демон умеет распознавать нумерованный промпт (waiting-статус), но варианты
не покидают `StatusMonitor.tickBody`. GUI не умеет отвечать на промпты без
фокуса в терминале и не имеет быстрого «ответить текстом». Срез добавляет:
события промптов, ответы `1-9`, reply-композер с драфтами, `⇧Tab`.

## 1. Демон: promptChanged

- `StatusMonitor`: новый колбэк `onPromptChanged: ((String, [String]) -> Void)?`
  и карта `prevPrompt: [String: [String]]`. В `tickBody` опции уже вычисляются —
  сравнить с прошлым тиком, при изменении эмитить (пустой массив = промпт
  ушёл). Прунинг вместе с остальными картами; исчезнувшая сессия с непустым
  промптом эмитит пустой набор.
- `DaemonEvent`: новый case `promptChanged(name: String, options: [String])`.
- `IPCServer.init`: подписка `monitor.onPromptChanged` → broadcast события
  (как statusChanged).
- `list` не меняется: после reconnect актуальный набор доезжает первым тиком
  (≤1.5 s) — приемлемо.

## 2. GUI-состояние (AppModel)

- `promptsByName: [String: [String]]` — из событий `promptChanged`; сессия
  удалена → ключ чистится (в `apply(event:)` на sessionRemoved/exited).
- `drafts: [String: String]` — персист (поле схемы уже есть): загрузка в
  `start()`, запись в `persist()`. Семантика TUI: Esc и пустая отправка
  сохраняют черновик; успешная отправка удаляет.
- `Modal.reply(String)` — имя сессии.
- Методы:
  - `answerPrompt(_ n: Int)` — если у выбранной сессии есть промпт и
    `n <= options.count`: `sendInput("\(n)\r")`;
  - `openReply()` — `modal = .reply(selected)`;
  - `sendReply(session:text:)` — trimmed; пустой → как Esc (сохранить
    черновик, закрыть); иначе `sendInput(bytes(text) + "\r")`, удалить
    черновик, закрыть;
  - `saveDraft(session:text:)` — пустой текст удаляет ключ.

## 3. Клавиши

| Контекст | Клавиша | Действие |
|---|---|---|
| normal | `1`-`9` | `.answerPrompt(n)` — только при активном промпте выбранной сессии (иначе `nil`, клавиша проходит дальше) |
| normal | `i` | `.openReply` (есть выбранная сессия) |
| normal | `⇧Tab` (backTab) | `.sendShiftTab` → `ESC[Z` в pty выбранной сессии |

Роутер остаётся чистым: `1-9` и `i` возвращают действия безусловно, guard
(есть ли промпт/выбор) — в `apply`. NB: `special == .tab && isShift` =
backTab; обычный Tab (toggleTab) требует `!isShift`.

Композер — шит, ввод у `TextEditor` (guard монитора на NSTextView):
- **Enter — отправить**, **⇧↵ — новая строка** (порт TUI; `onKeyPress(.return)`
  с проверкой шифта на TextEditor), ⌘↵ — тоже отправить;
- Esc (`.onExitCommand`) — сохранить черновик, закрыть;
- открытие восстанавливает черновик сессии.

## 4. UI

- **ReplySheet** (`Sheets.swift`): заголовок `Reply → {name}`, TextEditor
  (моноширинный, 6-8 строк), подпись-хинт `enter send · shift+enter newline ·
  esc save draft`, кнопки Cancel/Send.
- **Карточка сессии**: при непустом `promptsByName[name]` — ряд кнопок
  `1 yes · 2 no …` (кап по ширине, лейбл обрезается), клик = `answerPrompt`
  для ЭТОЙ сессии (выбирает её перед ответом).
- **Статус-бар**: в normal при активном промпте выбранной сессии подсказка
  дополняется `· 1-9 answer`; при непустом черновике выбранной — `· i draft`.

## 5. Тесты

- **StatusMonitorTests**: экран с меню → `onPromptChanged` с `["yes","no"]`;
  повторный тик без изменений — не эмитит; экран без меню → пустой набор;
  прунинг убитой сессии эмитит пустой.
- **ProtocolTests**: round-trip `promptChanged`.
- **AppModelTests/Chrome**: событие наполняет `promptsByName`; kill чистит;
  `answerPrompt` шлёт `"2\r"` (через перехват input — TestDaemon backfill
  или фейк); драфт: `saveDraft` персистится, `sendReply` непустой удаляет
  черновик и шлёт `text\r`, пустой — сохраняет и не шлёт; `openReply` ставит
  `Modal.reply`.
- **KeyRouterTests**: `1-9`/`i`/`⇧Tab` в normal; `⇧Tab` не путается с Tab;
  digits в selectSession-режиме по-прежнему прыгают (приоритет режима).
- ReplySheet Enter/⇧↵ — смоук.

## 6. Границы

- `parsePrompt` не меняем; verify/issue/usage-log — дальше; multiline paste
  в композер — стандартное поведение TextEditor.

## 7. Definition of Done

1. Сборка + полный набор тестов зелёные.
2. Смоук: сессия с нумерованным промптом (claude с выбором) → кнопки на
   карточке; `2` из списка отвечает; `i` — композер, Enter шлёт текст +
   Enter агенту; ⇧↵ — перенос строки; Esc — черновик (переживает перезапуск,
   `i` восстанавливает, после отправки исчезает); `⇧Tab` циклит режим claude.
3. Vim off: кнопки вариантов на карточках кликабельны; reply-композер —
   vim-удобство (`i`), мышиный эквивалент — ввод прямо в живом терминале,
   отдельный пункт меню не нужен.
