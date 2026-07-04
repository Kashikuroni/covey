# Слайс 17 — lifecycle: restart, restart-all-claude, return-to-root (Design Spec)

> Порт lifecycle-механики TUI (`ConfirmRestart`/`RestartAllClaude`/`ReturnToRoot`,
> `RestartReq`, `parse_resume_command`) на демон-модель covey. В отличие от TUI
> (remain-on-exit + ловля resume-подсказки из мёртвой панели + 30с таймаут)
> демон владеет процессом и scrollback'ом — рестарт детерминирован, таймаут и
> «мёртвая панель» не нужны.

## 1. Цель

- **Одиночный рестарт** выбранной сессии (в TUI нет; у нас тот же код-путь):
  агент перезапускается в том же dir, claude — с resume.
- **Restart-all-claude** (`space a u` в TUI): перезапуск всех claude-сессий с
  typed-подтверждением «yes»/«да».
- **Return-to-root**: сессия, чей worktree снесён (промоутом из другой сессии,
  cleanup'ом, руками), возвращается в корень репо — claude рестартом с resume,
  шелл — командой `cd <root>`.
- Попутно: свежий resume-uuid при КАЖДОМ выходе claude (ловит `/clear`),
  чинит и Recent-записи.

## 2. Демон

### parse_resume_command (порт `amux-core/tmux/parse.rs`)

Чистая функция в `/covey/Sources/CoveydCore/StatusInference.swift` (рядом с
существующей ANSI-обработкой) или соседнем файле:

- `parseResumeCommand(_ tail: String) -> String?` — ищет с конца по строкам
  последнее вхождение `claude --resume `; дальше либо uuid-токен
  (`[0-9a-fA-F-]`, длина ≥ 8), либо имя в двойных кавычках со строгой
  валидацией (значение попадает в `sh -c` — метасимволы = инъекция; порт
  `is_resume_uuid`/`is_resume_name` 1:1). Вход предварительно очищается от
  ANSI/CSI (порт `strip_ansi`, если эквивалента ещё нет).
- Хвост берётся из `ScrollbackBuffer.since(max(headSeq, tailSeq − 4096))`.

### Свежий resumeCmd на выходе claude

`SessionRegistry.handleExit`, ДО удаления записи и `exited`-события: если
`meta.resumeCmd != nil` (значит claude-сессия) — парсить хвост scrollback;
нашли и uuid отличается — обновить `meta.resumeCmd`, persist и отправить
`sessionAdded` с обновлённой Session (клиентский обработчик — upsert,
`AppModel.swift:691`) ПЕРЕД `exited`. GUI строит Recent-запись из своего
кэша Session — к моменту `exited` кэш уже несёт свежий uuid. Не нашли —
оставить хранимый, ничего не слать.

### SessionRegistry.restart

- `restart(name: String, dir: String?) throws`:
  guard сессия существует; `pendingRestart[name] = dir ?? entry.dir`;
  `kill(name)` (существующая SIGHUP→SIGKILL эскалация).
- `handleExit`, когда имя помечено в `pendingRestart` (проверка ДО ветки
  удаления): запись НЕ удаляется, `exited`/`sessionRemoved` НЕ шлются.
  Вместо этого:
  1. resume-парс как выше (обновить `meta.resumeCmd`);
  2. команда респауна: claude с `resumeCmd` →
     `resumeLaunchCommand(resumeCmd)` (фолбэк-обёртка 15.1 покрывает
     разговор-без-сообщений) через тот же `/bin/sh -c` + resolve; иначе —
     исходный `meta.argv` без изменений;
  3. новый `PTYProcess` в `pendingRestart`-директории; `entry.dir` (и meta)
     обновляются, если dir сменился; persist;
  4. последний известный winsize переприменяется (`resize` новому PTY);
  5. экран (ScreenModel) записи продолжает жить; серверный scrollback лежит
     ВНУТРИ PTYProcess, поэтому у нового процесса он начинается заново
     (backfill свежей подписки отдаёт только пост-рестартный вывод) — история
     в открытом терминале сохраняется клиентской стороной (SwiftTerm), поток
     output-событий переподцепляется демоном, клиент ничего не делает;
  6. событие: `sessionAdded(session)` с обновлённой Session — клиентский
     обработчик уже upsert (`AppModel.swift:691`), отдельный case не нужен.
- Целевая директория обязана существовать: guard в `restart` (для
  return-to-root корень репо существует по определению; для одиночного —
  дир сессии мог быть снесён: тогда ошибка `restartFailed`).

### Протокол

- `Request.Op` + `case restart(name: String, dir: String?)` → `.ok` /
  `.error(code: "restartFailed", …)`. `dir` — только для return-to-root.
- `IPCClient.restart(name:dir:)`; `IPCServer.dispatch` кейс.
- Новых событий нет (upsert через `sessionAdded`).

## 3. GUI

### Одиночный рестарт

- Чорд `space s u` (session-меню) для выбранной сессии → `Modal.restart(name)`
  — обычный confirm-sheet в стиле Kill («Restart '<name>'? claude resumes the
  conversation; other agents relaunch fresh.») → `model.restart(name)` →
  `client.restart(name: name, dir: nil)`. Ошибка — inline в sheet.

### Restart-all-claude

- Чорд `space a u` (app-меню) → `Modal.restartAll` — sheet с TextField;
  кнопка/Enter активны только когда введено подтверждение: порт
  `confirms_restart` — trim + lowercase, ровно `yes` или `да` (чистая
  функция `confirmsRestart(_:) -> Bool` в GUI-таргете).
- Действие: по всем `sessions` с первым словом агента `claude` —
  `client.restart(name:, dir: nil)` последовательно; ошибки собираются в toast.

### Return-to-root

- Предикат «returnable» (чистая функция, инъекция dirExists для тестов):
  `worktreeRepo != nil && !dirExists(dir)` — проверка каталога на диске, а не
  `git == nil` (git ещё nil у свежесозданной сессии до первого опроса
  GitMonitor — был бы ложный бейдж). На карточке вместо git-строки —
  `⧉ worktree removed` (secondary).
- Действие в git-меню: `space g r` («return to root»; в git-меню заняты
  `p`/`b`/`c`, `r` свободна). Guard: только для returnable-сессий, иначе
  toast.
- Исполнение (порт ReturnToRoot): агент claude → `model.restart(name,
  dir: worktreeRepo)`; иначе (шелл/другой агент) → `client.input` строки
  `cd <root>\n` с shell-quoting корня (порт `shell_single_quote`).
- Без confirm-sheet (как в TUI — прямое действие).

### Хелп/WhichKey

Новые чорды в HelpOverlay и WhichKeyView: `s u`, `a u`, `g r` (в
session-меню занято `r`/`R` — `u` свободна; app-меню пусто в KeyRouter,
`u` свободна).

## 4. Тесты

- **CoveydCoreTests**: `parseResumeCommand` — порт кейсов parse.rs (uuid,
  кавычки+валидация имени, ANSI-мусор, пусто, инъекция отвергается);
  registry-рестарт на настоящем PTY (`/bin/cat`): respawn жив, entry тот же,
  без `exited`/`sessionRemoved`, dir-override меняет `entry.dir`,
  respawn стартует с последним известным winsize; claude-ветка: respawn-argv содержит
  `--resume`-обёртку (агент подменяется скриптом, печатающим resume-подсказку
  перед выходом → `meta.resumeCmd` обновлён); обычный exit обновляет
  resumeCmd до `exited`; несуществующий dir → `restartFailed`.
- **Протокол**: round-trip `.restart` (dir nil/не-nil).
- **CoveyAppTests**: `confirmsRestart` («yes», «Да », «ДА», отказ «y»,
  «yes!», пусто); returnable-предикат; KeyRouter: `space s u`, `space a u`,
  `space g r` → нужные экшены. Фильтр restart-all (только claude-агенты) —
  смоук (пункт 2).
- Смоук: рестарт живой claude-сессии из GUI, рестарт-олл, снос worktree
  промоутом из второй сессии → карточка returnable → возврат в корень.

## 5. Границы

- PromoteOp-через-рестарт (deferred promote TUI) — нет: promote уже
  реализован иначе (срез 16) и работает.
- Verify, OpenEditor, Issue, UsageLog — следующие срезы.
- Рестарт НЕ-claude агентов с сохранением контекста — нет (перезапуск argv
  как есть).
- Автодетект умершего claude с предложением рестарта — нет.
