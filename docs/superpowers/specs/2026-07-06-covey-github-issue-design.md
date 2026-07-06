# Слайс 24 — `space g i`: GitHub issue через gh (Design Spec)

> Порт amux-tui modal_issue + git.rs spawn_issue_create: композер
> title/body, асинхронный `gh issue create` в директории сессии, URL в
> клипборд. GUI-only — демон/протокол не меняются.

## 1. Вызов и гарды

- `KeyAction.createIssue`; `routeLeader`: `(.git, "i")`.
- `apply(.createIssue)`: `inputMode = .normal`; нет selected → тост
  «no session»; `selectedSession().git == nil` → тост «not a git repo»;
  иначе `modal = .issue(s.dir)` (dir сессии: у worktree-сессии — сам
  worktree, gh найдёт репо по общему remote).
- WhichKeyView, группа git: `i` — «create github issue»,
  `implemented: true`.
- HelpOverlay, строка leader g: убрать «issue (later)» → «issue».

## 2. IssueService (`Sources/covey/IssueService.swift`, новый)

```swift
enum IssueService {
    /// gh issue create in `dir`; .success = the new issue's URL.
    static func create(dir: String, title: String, body: String) async -> Result<String, String>
}
```

- `Process`: executable `/usr/bin/env`, args
  `["gh", "issue", "create", "--title", title, "--body", body]`,
  `currentDirectoryURL = dir`. Аргументы НЕ проходят через шелл —
  инъекций нет.
- Запуск/ожидание на background-очереди внутри async (сетевой вызов;
  UI не блокировать).
- Разбор результата:
  - запуск упал (нет gh) → `.failure("gh CLI not found — install it
    (brew install gh), then `gh auth login`")`;
  - код ≠ 0 → `.failure(stderr.trimmed)`, пустой stderr → «gh issue
    create failed»;
  - код 0 → `parseIssueURL(stdout)`; nil → `.failure("issue created,
    but gh printed no URL — check GitHub")`.
- `parseIssueURL(_ stdout: String) -> String?` — чистая: последняя
  непустая строка stdout, обрезанная; нет такой → nil (gh печатает URL
  последней строкой).

## 3. IssueSheet (Sheets.swift)

`Modal.issue(String)` (dir). Вид (порт modal_issue):

- Заголовок «New issue», строка `in: <collapseHome(dir)>` (для
  worktree-сессии это сам worktree — честно показывает, откуда уйдёт
  gh-вызов).
- **title** — TextField в AyuField, фокус при открытии.
- **body** — `TextEditor` (многострочный), ~8 строк, ayu-рамка в стиле
  AyuField (surf2 + bd2/accent по фокусу), mono 12.
- Клавиши: `Tab` — title↔body; `⇧Enter` — создать (из любого поля);
  `Esc` — отмена/закрыть; Enter в body — перенос строки, Enter в
  title — фокус в body.
- Подсказка: «⇧enter create · tab field · esc cancel».
- Кнопки Cancel / Create (Create disabled при пустом title).

### Стадии (state внутри шита)

`enum IssueStage { case editing, creating, done(String), failed(String) }`

- **creating**: «creating issue…» + «esc hide — gh keeps running». Esc закрывает модалку, Task живёт; по завершении URL всё
  равно копируется в клипборд (тост «issue created — URL copied» /
  «issue failed: …» если шит уже закрыт).
- **done(url)**: «✓ issue created», URL, «(copied to clipboard)», «any
  key to close» — любой keypress/Esc закрывает. Копирование в
  NSPasteboard при переходе в done.
- **failed(err)**: «✕ issue not created» + err красным, «any key to
  close».

## 4. Тесты

- KeyRouterTests: `space g i` → `.createIssue`.
- AppModelChromeTests: гарды — без selected тост «no session», сессия
  без git → «not a git repo», с git → `modal == .issue(dir)`.
- IssueServiceTests (новый): `parseIssueURL` — обычный stdout с URL
  последней строкой, многострочный stdout, пустая строка/пробелы → nil.
- Живой `gh` из тестов не вызывается.

## 5. Смоук (user)

Рестарт демона не нужен.

1. Сессия в репо с github-remote → `space g i` — композер: repo-имя,
   title в фокусе.
2. Tab → body, текст с переносами; `⇧Enter` — «creating…», затем
   «✓ issue created» + URL; URL в клипборде; any key закрывает.
   Issue реально появился на GitHub.
3. Сессия в репо без remote/без auth → failed-стадия с текстом gh.
4. Сессия вне git → тост «not a git repo», шит не открылся.
5. Esc во время creating — шит закрылся, по завершении тост, URL в
   клипборде.
