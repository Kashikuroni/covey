# Slice 15 — полное создание сессий: worktree, terminal, пресеты, model/effort, resume (Design Spec)

> Дата: 2026-07-02
> Источник: порт `amux-core/create.rs` (CreateSpec/compose_launch/validate/
> efforts/resolve, worktree-оркестрация) и `git.rs` (prepare_worktree +
> stale-очистка, worktree_for_branch, remove_worktree), форма `modal_new.rs`
> — нативной формой, не пошаговым визардом (HANDOFF: reinterpret natively).
> Решения: git-исполнение в демоне; resume-вайринг сразу; пресеты из
> `~/.covey/config.json`.

## 0. Контекст

Текущий create — голый (dir, agent, argv=[agent]). TUI умеет: терминальные
сессии ($SHELL), worktree-флоу (новая ветка от base / существующая с
переиспользованием чекаута), model/effort для claude, `--session-id` +
resume-команду в Recent, пресеты агентов. Всё это — в демон и форму.

## 1. CoveydCore/GitOps.swift (порт git.rs, только нужное)

Синхронные обёртки над `Process("git", "-C", …)`:
- `repoRoot(_ dir: String) -> String?` (`rev-parse --show-toplevel`)
- `currentBranch(_ repo: String) -> String?` (`branch --show-current`)
- `localBranches(_ repo: String) -> [String]` (`branch --list --format=%(refname:short)`)
- `branchExists(_ repo: String, _ branch: String) -> Bool`
- `worktreeForBranch(_ repo: String, _ branch: String) -> String?`
  (`worktree list --porcelain` парсинг)
- `ensureGitignore(_ repo: String, entry: String)` — дописывает `.worktrees/`
  в `.gitignore`, если нет
- `prepareWorktree(repo:wtPath:newBranch:base:) throws` — порт: ошибка если
  ветка существует; stale-очистка (`worktree prune` + снос непустого
  каталога, не зарегистрированного как worktree; пустой оставить);
  `worktree add -b`
- `prepareWorktreeExisting(repo:wtPath:branch:) throws` — та же очистка,
  ветка должна существовать, `worktree add` без `-b`
- `removeWorktree(repo:wtPath:)` (`worktree remove --force`)
- `resolveAgentPath(_ cmd: String) -> String?` — первое слово через
  `sh -c 'command -v -- "$0"' <bin>` (инъекция исключена, как в Rust)

Ошибки — `throws` с человекочитаемым текстом (уходит клиенту в
`.error(code:"createFailed")`).

## 2. Порт create.rs: CoveyKit/CreateLogic.swift (pure) + CoveydCore/CreateService.swift (IO)

Pure-часть живёт в **CoveyKit** — её используют и демон (сборка команды), и
GUI (превью команды, effort-таблицы формы), без дублирования. `WorktreeSpec`
тоже в CoveyKit: он часть протокола.

```swift
// CoveyKit/CreateLogic.swift
public enum WorktreeSpec: Codable, Equatable {
    case new(branch: String, base: String)
    case existing(branch: String)
}

public struct CreateSpec {
    var name: String?          // nil → авто s-N (как сейчас)
    var dir: String            // абсолютный, tilde уже раскрыт
    var agent: String
    var terminal: Bool
    var worktree: WorktreeSpec?
    var model: String?         // claude only
    var effort: String?        // claude only
    var resume: String?        // relaunch: готовая команда "claude --resume <uuid>"
}
```

- Pure в CoveyKit (табличные тесты — порт rust-кейсов):
  - `claudeModels = ["opus", "sonnet", "haiku"]`;
    `effortLevels(model:)`: opus `auto/low/medium/high/xhigh/max`, sonnet без
    `xhigh`, haiku `[auto]`; `auto` = флаг не передаётся;
  - `composeAgentCommand(agent:model:effort:)` → `"claude --model m --effort e"`;
  - `composeLaunch(spec:uuid:) -> (command, label, resumeCmd)`: terminal →
    (`$SHELL`, басенейм шелла, nil); claude+uuid → `… --session-id <uuid>` +
    `"claude --resume <uuid>"`; `resume != nil` → команда = resume, новый
    resumeCmd = тот же (возобновлённая сессия остаётся возобновляемой);
  - `validateCreate(name:dir:existing:)` (имя без `:`/`.`; дир существует),
    `validateBranch` (не пустая, не с `-`, не абсолютная, без `.`/`..`
    сегментов).
- IO в CoveydCore/CreateService.swift —
  `prepare(spec:) throws -> Prepared {finalDir, argv, label, worktreeRepo?, resumeCmd?}`:
  uuid = `UUID().uuidString.lowercased()` для чистого claude; worktree-ветвление
  1:1 с `create_worktree_session` (New → gitignore+prepareWorktree в
  `<repo>/.worktrees/<branch>`; Existing → чекаут в корне → сессия в корне
  без worktreeRepo; чекаут в linked worktree → там; нигде → добавить);
  argv: terminal → `[$SHELL]`, агент → `["/bin/sh", "-c", resolvedCommand]`
  (резолв первого слова в абсолютный путь).

## 3. Протокол

- `Op.create(dir:agent:argv:name:)` расширяется optional-полями
  `terminal: Bool?`, `worktree: WorktreeSpec?`, `model: String?`,
  `effort: String?`, `resume: String?` (старые клиенты декодятся с nil).
  `argv` остаётся для тестов/совместимости: если задан — путь как сейчас,
  минуя CreateService.
- Новый `Op.gitInfo(dir: String)` → новый
  `Result.gitInfo(repoRoot: String?, currentBranch: String?, branches: [String])`.
- `Op.kill(name:)` + `removeWorktree: Bool?`.
- `Session` + `resumeCmd: String?` (optional Codable); `worktreeRepo`
  заполняется. `SessionMeta` + `resumeCmd`, `worktreeRepo`.
- `IPCClient`: `create(...)` с новыми параметрами, `gitInfo(dir:)`,
  `kill(name:removeWorktree:)`.

## 4. Демон: registry + dispatch

- `IPCServer.dispatch .create`: argv задан → как сейчас; иначе
  `CreateService.prepare` (git-IO ВНЕ локов registry) → `registry.create`
  с готовыми (dir=finalDir, argv, label→agent, worktreeRepo, resumeCmd).
- `SessionRegistry.create` расширяется параметрами `worktreeRepo`,
  `resumeCmd` (в Session и SessionMeta; персист как раньше).
- `kill(removeWorktree: true)`: registry помечает сессию
  (`pendingWorktreeRemoval`); в `handleExit` после удаления записи —
  `GitOps.removeWorktree(repo, dir)` (только если `worktreeRepo != nil`).
- `.gitInfo`: `repoRoot` + `currentBranch` + `localBranches` (пустые/-nil для
  не-репо).

## 5. GUI

- **Config**: `CoveyKit/CoveyConfig.swift` — `load()` из
  `~/.covey/config.json`: `{ defaultAgent: String?, agentPresets: [String]? }`;
  дефолт `["claude", "codex"]` + слот custom.
- **NewSessionSheet** — полная форма:
  - Name (плейсхолдер «auto»), Directory (TextField + Browse, tilde-expand,
    inline-валидация); на изменение dir — `client.gitInfo` (debounce);
  - Terminal toggle;
  - git-блок (repoRoot != nil): Worktree toggle; Branch — typeahead-поле со
    списком веток + пункт `+ create "<ввод>"`; Base (для новой ветки) —
    фильтруемый список веток, дефолт currentBranch;
  - Agent-блок (скрыт при terminal): Picker пресетов + custom-поле; для
    claude — Model (`opus/sonnet/haiku`) и Effort (segmented по
    `effortLevels`, `auto` дефолт);
  - превью команды (`composeAgentCommand` из CoveyKit/CreateLogic, §2);
  - inline-ошибка от валидации/демона; Create — default action.
- **KillSheet**: для сессии с `worktreeRepo` — Toggle «also remove worktree»
  → `kill(removeWorktree:)`.
- `relaunchRecent`: `create(dir:agent:resume: r.resumeCmd)`;
  `pushRecent` несёт `resumeCmd` из Session (exited и lost пути).

## 6. Тесты

- **CreateLogicTests** (CoveyKit-уровень, в CoveyAppTests): порт rust-кейсов
  compose/validate/effort + resume-композиция.
- **GitOpsTests** (CoveydCoreTests): временный НАСТОЯЩИЙ git-репо
  (`git init` + commit в setUp): repoRoot/branchExists/localBranches/
  prepareWorktree (new: каталог+ветка; существующая ветка → ошибка)/
  prepareWorktreeExisting/worktreeForBranch/removeWorktree/ensureGitignore
  (идемпотентность)/stale-очистка (orphan-каталог сносится).
- **IPCServer/Registry**: create c worktree(new) в temp-репо → Session.dir =
  `<repo>/.worktrees/<branch>`, worktreeRepo = repo, ветка создана; terminal
  create → argv=[$SHELL]; resume create → команда resume; kill(removeWorktree)
  → каталог исчез после exit; gitInfo round-trip + для не-репо; протокол
  round-trip новых полей.
- **AppModel**: relaunchRecent шлёт resume; exited → RecentSession.resumeCmd.
- Форма — смоук.

## 7. Границы

- Git-инфо на карточках (⎇/⧉/±) — срез 16; promote/delete/cleanup — срез 16;
  restart-all — позже.

## 7.1 Дополнение (по фидбеку смоука): форма — полный порт TUI-управления

NSOpenPanel/Browse УДАЛЯЕТСЯ. Форма управляется только клавиатурой, как
`modal_new`:
- **Dir-пикер** (порт `browse.rs`): под полем — живой список сабдиректорий;
  `split_path` (база до последнего `/` + фильтр-хвост), case-insensitive
  префикс-фильтр, скрытые каталоги видны только когда фильтр начинается с
  `.`, сортировка case-insensitive, кап 200 записей (имя проверяется до
  stat, ранний выход); `↓`/`↑` ходят по списку с wrap, `Tab`/`→` спускается
  (dir = база + выбранный + "/"), пересчёт на каждый ввод.
- **Цепочка полей** (порт `field_sequence`): Name → Dir → Terminal →
  [Worktree → Branch → [Base]] → [Agent → [custom] → [Model → Effort]];
  `Enter` — следующее поле, `⇧Enter` — submit из любого места, `Esc` —
  отмена. Не-текстовые ряды фокусируемы: `Space`/`←`/`→` тогглят и циклят
  (agent-пресеты — порт `cycle_agent` с wrap и сбросом model/effort);
  claude-детект по первому слову команды (кастом `claude --x` тоже claude).
- Pure-логика выносится и тестируется: `splitPath`, `listSubdirs`
  (`DirBrowse.swift`), `formFieldSequence(...)`.
- Мышь вторична, но работает (клик по строке пикера/тогглу).

## 8. Definition of Done

1. Сборка + полный набор тестов зелёные. Смоук — с ОБЯЗАТЕЛЬНЫМ рестартом
   демона (`pkill -f coveyd; rm -f ~/.covey/coveyd.sock`).
2. Смоук:
   - `n` → форма: terminal-сессия открывает шелл; claude с model/effort —
     превью и реальная команда с флагами;
   - в git-репо: worktree + новая ветка от base → сессия в
     `.worktrees/<ветка>`, ветка создана, `.gitignore` дополнен;
   - worktree + существующая ветка, уже чекаутнутая в корне → сессия в корне;
   - kill той worktree-сессии с галкой → каталог worktree удалён;
   - claude-сессия → kill → Recent → Relaunch → разговор ВОЗОБНОВИЛСЯ
     (`--resume`); то же после рестарта демона (lost → Recent → resume);
   - пресеты из config.json подхватываются (создать файл руками).
3. Vim off: форма полностью управляется мышью.
