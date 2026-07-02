# Slice 16 — git-действия (promote/delete/cleanup) + git-инфо на карточках (Design Spec)

> Дата: 2026-07-02
> Источник: порт `amux-core/git.rs` (promote_worktree со stash-переносом,
> delete_branch `-d`, list_merged_branches, PROTECTED_BRANCHES, read/parse_shortstat)
> и `amux-tui/modal_git.rs` (три GitAction с клавишами). Направление:
> `keyboard-first-priority`. Git graph — по-прежнему отложен.

## 0. Контекст

Leader-группа `g` — вся серая; `Session.git` пустует со среза 5. Срез
оживляет карточки (`⎇ branch +a −d`) и три действия: promote worktree в
корень, удаление ветки сессии, чистка merged-веток.

## 1. GitOps-расширения (CoveydCore, порт git.rs)

- `isDirty(dir)` — `status --porcelain` непуст;
- `stashPush(dir)` — `stash push --include-untracked -m covey-promote`;
- `stashPop(dir)`;
- `checkout(repo:branch:)`;
- `promoteWorktree(repo:wtDir:branch:) throws` — порт 1:1: dirty → stash;
  `worktree remove` (без --force); checkout ветки в корне; dirty → stash pop
  в корне (stash живёт в общем `.git`); ошибки прерывают цепочку;
- `deleteBranch(repo:branch:) throws` — `branch -d` (unmerged откажет git);
- `listMergedBranches(repo) -> [String]` — `branch --merged HEAD
  --format=%(refname:short)`, минус текущая ветка; protected ВКЛЮЧЕНЫ
  (вызывающий показывает их залоченными);
- `readGitInfo(dir) -> GitInfo?` — branch (`branch --show-current`, пустой →
  `rev-parse --short HEAD`) + `diff --shortstat` через `parseShortstat`
  (added=insertions, removed=deletions); не-репо → nil;
- Все ЧТЕНИЯ — env `LC_ALL=C` (парсим английские слова) и
  `GIT_OPTIONAL_LOCKS=0` (не виснуть на залоченном индексе); мутации — без
  optional-locks.
- `parseShortstat(_ s: String) -> (added: Int, removed: Int)` — pure, порт.
- **CoveyKit**: `public let protectedBranches = ["main", "master", "develop", "dev"]`
  (нужен GUI для локов) — GitOps ссылается на него.

## 2. GitMonitor (демон)

Новый `CoveydCore/GitMonitor.swift` по образцу StatusMonitor: таймер ~5 с
(инжектируемый интервал), снапшот живых сессий `(name, dir)` через колбэк,
для каждой `readGitInfo`; при отличии от прошлого значения —
`onGitChanged?(name, GitInfo?)`. Прунинг исчезнувших сессий. `tick()` для
тестов. Wiring в `coveyd/main.swift` и `TestDaemon`:
`GitMonitor(snapshot: { registry.list().map { ($0.name, $0.dir) } })`;
`onGitChanged` → `registry.updateGit(name:git:)` + broadcast события.

- `SessionRegistry.updateGit(name:git:)` — мутирует `entries[name].session.git`
  (под локом), без persist (transient) и без onSessionAdded.
- `DaemonEvent.gitChanged(name: String, git: GitInfo?)` — новый case.
- `list` несёт git внутри Session автоматически.

## 3. Протокол

- `Op.promote(name: String)` → `.ok`/`.error("promoteFailed", текст)`.
  Демон: сессия существует, `worktreeRepo != nil` (иначе «not a worktree
  session»), branch — `GitOps.currentBranch(session.dir)` НАПРЯМУЮ (не кэш
  GitMonitor — тот может ещё не тикнуть) → `GitOps.promoteWorktree`.
  Процесс сессии не трогаем (TUI-паритет).
- `Op.deleteBranch(dir: String, branch: String)` → protected → ошибка
  «branch 'X' is protected»; иначе `GitOps.deleteBranch`.
- `Op.mergedBranches(dir: String)` → новый `Result.branches([String])`
  (не-репо → пустой список).
- `Op.cleanupBranches(dir: String, branches: [String])` — по очереди `-d`,
  ошибки копятся; всё ок → `.ok`, иначе `.error("cleanupFailed",
  «x: причина; y: причина»)` (удачные — удалены).
- `IPCClient`: `promote(name:)`, `deleteBranch(dir:branch:)`,
  `mergedBranches(dir:) -> [String]`, `cleanupBranches(dir:branches:)`.

## 4. GUI

- **Карточки** (SessionListView.row, строка агента): при `session.git != nil`
  — `⧉` (worktreeRepo != nil) или `⎇`, имя ветки, `+a −d` (нули прячем);
  событие gitChanged обновляет `sessions[i].git` в `apply(event:)`.
- **Роутер**: `(.git, "p") → .promoteSelected`, `("b") → .deleteBranchSelected`,
  `("c") → .cleanupBranches`; which-key: пункты белеют.
- **apply + гарды** (ошибки — toast):
  - promoteSelected: выбранная сессия с `worktreeRepo != nil` →
    `Modal.promote(name)`; иначе no-op c toast «not a worktree session»;
  - deleteBranchSelected: выбранная, НЕ worktree (TUI-гард), git есть,
    ветка не protected → `Modal.deleteBranch(name)`; нарушения — toast
    («cannot delete: worktree session» / «no git» / «protected branch»);
  - cleanupBranches: выбранная сессия в репо → `Modal.cleanup(dir)`.
- **Шиты** (клавиатура по паттерну среза 15):
  - PromoteSheet: ветка + путь worktree + предупреждение «uncommitted
    changes move to the repo root via stash»; `y`/Enter — promote (успех →
    закрыть; ошибка — inline), `n`/Esc — отмена.
  - DeleteBranchSheet: «Delete branch 'X'? (git branch -d — merged only)»;
    `y`/Enter / `n`/Esc; ошибка `-d` (unmerged) — inline.
  - CleanupSheet: список merged-веток (запрашивается при открытии);
    protected — 🔒, невыбираемые; остальные предвыбраны (TUI-паритет);
    `j`/`k`/`↑`/`↓` курсор, `Space` тоггл, `a` — выбрать все непротектед,
    `y`/Enter — удалить выбранные, `Esc` — отмена; пусто → «no merged
    branches» и только Esc/Close.
- Клавиши шитов — локальные (`onKeyPress` на focusable-контенте шита;
  глобальный роутер молчит при `sheetOpen`).

## 5. Тесты

- **GitOpsTests** (temp-репо): parseShortstat (таблица), readGitInfo (репо
  с диффом: added/removed; не-репо → nil; detached HEAD → короткий хеш);
  promote: worktree с untracked-файлом → после promote файл в корне, ветка
  чекаутнута, worktree снесён; deleteBranch merged ок / unmerged бросает;
  listMergedBranches: merged видна, текущая исключена, protected включён.
- **GitMonitorTests**: первый tick эмитит, без изменений молчит, изменение
  диффа эмитит, исчезнувшая сессия прунится.
- **ProtocolTests**: round-trip новых op/result/event.
- **IPCServerTests**: promote не-worktree → ошибка; deleteBranch protected →
  ошибка; mergedBranches/cleanup на temp-репо.
- **KeyRouterTests**: `(.git, p/b/c)`.
- **AppModelChromeTests**: гарды apply (toast/Modal), gitChanged обновляет
  карточную инфу.
- Полный набор зелёный. Смоук — с рестартом демона.

## 6. Границы

- Returnable + `⌃r` (детект снесённого worktree на карточке) — не в срезе;
  `-D` force — нет; git graph — нет; авто-kill сессии при promote — нет.

## 7. Definition of Done

1. Сборка + полный набор тестов зелёные.
2. Смоук (демон рестартован):
   - карточки показывают `⎇/⧉ ветка +N −M`, диф обновляется ≤5 с после
     правки файла;
   - worktree-сессия: `space g p` → подтверждение → ветка чекаутнута в
     корне, worktree исчез, незакоммиченный файл переехал в корень;
   - обычная сессия на фиче-ветке: `space g b` → ветка удалена; на
     protected — toast-отказ;
   - `space g c` → список merged, `Space`/`a`/`y` — выбранные удалены,
     protected залочены;
   - which-key: группа `g` белая.
3. Vim off: шиты кликабельны мышью.
