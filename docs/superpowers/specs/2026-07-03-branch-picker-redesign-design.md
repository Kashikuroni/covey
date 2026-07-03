# Слайс 15.1 — редизайн выбора ветки в форме создания сессии (Design Spec)

> Follow-up к слайсу 15 (`2026-07-02-covey-create-full-design.md`). Чинит
> баг рендера списка веток и меняет UX git-блока формы NewSessionSheet:
> typeahead-поле ветки вместо cycleRow, checkout в корне без worktree,
> авто-переход в существующий worktree.

## 1. Проблема и цель

- **Баг:** ветки рендерятся `cycleRow` — горизонтальный HStack чипов. При
  десятках веток HStack сжимает каждый Text до ширины ~1 символа, текст
  ломается по буквам вертикально. Для agent/model/effort (3–4 коротких
  опции) cycleRow работает и остаётся.
- **UX-цель:** поле ветки работает как dir-пикер — фильтруемый список под
  инпутом; чекбокс «Create worktree» под полем; для новой ветки — второй
  такой же инпут для base; ветка с существующим worktree → без чекбокса,
  сессия открывается в этом worktree.

## 2. UX формы (git-блок, виден при repoRoot != nil)

Расположение: сразу после Terminal toggle, вместо старых Worktree
toggle + Branch cycleRow + New-branch TextField + Base cycleRow.

- **Поле Branch**: пустое при открытии, placeholder
  `branch (current: <currentBranch>)`. Пустое поле = остаться на текущей
  ветке (worktree = nil, сессия в dir как есть) — чекбокса и подсказок нет.
- **Список под полем** (при фокусе): ветки, отфильтрованные
  case-insensitive префиксом от введённого текста; ↓/↑ ходят с wrap,
  Tab/→/клик подставляют полное имя в поле (→ — только когда список
  непуст, с тем же caret-гардом, что у dir); показываются первые 8 +
  `… N more`; механика 1:1 с dir-пикером. Ветки, чекнутые в linked
  worktree, помечены приглушённым `⧉` после имени (глиф worktree с
  карточек); текущая ветка не помечается.
- **Точное совпадение отсутствует** (ветка новая): под списком (или вместо
  него, когда префикс-фильтр пуст) строка `will create branch "<имя>"` —
  список префиксных совпадений остаётся видимым, пока он непуст.
- **Ветка есть в карте worktrees** (включая текущую — главный worktree):
  вместо чекбокса подсказка `opens in: <путь>` (tilde-collapse). Чекбокс
  скрыт — worktree уже существует, сессия откроется в нём.
- **Чекбокс «Create worktree»**: виден только когда поле непустое И ветки
  нет в карте worktrees (существующая без worktree или новая). По
  умолчанию снят.
- **Поле Base**: тот же typeahead-компонент (существующие ветки, без
  «create»-режима), появляется только когда ветка новая. Пустое поле =
  currentBranch (плейсхолдер `base (default: <current>)`). Непустое
  значение обязано быть существующей веткой — иначе inline-ошибка.
- **Enter-цепочка**: … → dir → terminal → branch → [worktree-чекбокс] →
  [base] → agent → … (⇧Enter — submit, как раньше).

### Маппинг на submit (branchPlan)

| Поле Branch | Чекбокс | WorktreeSpec | Итог |
|---|---|---|---|
| пусто или == current | скрыт | `nil` | сессия в dir как есть |
| ветка с worktree | скрыт | `.checkout(branch)` | демон резолвит путь worktree (корень → обычная сессия) |
| существующая, без worktree | ☐ | `.checkout(branch)` | `git switch` в корне, сессия в корне |
| существующая, без worktree | ☑ | `.existing(branch)` | worktree в `.worktrees/<branch>` |
| новая | ☐ | `.checkoutNew(branch, base)` | `git switch -c <branch> <base>` в корне |
| новая | ☑ | `.new(branch, base)` | worktree + новая ветка |

Валидация на submit: для новой ветки `validateBranch`; непустой base
обязан существовать в branches.

Грязное дерево/конфликт при `git switch` → ошибка демона всплывает в
inline-ошибке формы (как остальные ошибки create).

## 3. CoveyKit

### Протокол (`/covey/Sources/CoveyKit/Protocol.swift`, `CreateLogic.swift`)

- `WorktreeSpec` + два кейса:
  - `case checkout(branch: String)` — переключиться на существующую ветку
    без создания worktree (или открыть её существующий worktree);
  - `case checkoutNew(branch: String, base: String)` — создать ветку в
    корне репо и переключиться.
- `Result.gitInfo` расширяется:
  `gitInfo(repoRoot: String?, currentBranch: String?, branches: [String], worktrees: [String: String])`
  — карта «ветка → абсолютный путь worktree», включая главный worktree
  (= корень репо); detached-worktree'ы без ветки в карту не попадают.
- `IPCClient.gitInfo(dir:)` возвращает кортеж с `worktrees`.

### Чистая логика (`/covey/Sources/CoveyKit/CreateLogic.swift`)

- `filterBranches(_ branches: [String], query: String) -> [String]` —
  case-insensitive префикс; пустой query → все.
- `branchPlan(input: String, current: String?, branches: [String],
  worktrees: [String: String], createWorktree: Bool, base: String)
  -> WorktreeSpec?` — таблица из §2 (input/base триммятся; пустой base →
  `current ?? branches.first ?? ""`). Точное совпадение имени —
  case-sensitive (имена веток в git регистрозависимы).

Обе функции — pure, тестируются в CoveyKitTests без UI.

## 4. Демон

### GitOps (`/covey/Sources/CoveydCore/GitOps.swift`)

- `worktrees(_ repo: String) -> [String: String]` — парсинг
  `git worktree list --porcelain` (пары `worktree <path>` /
  `branch refs/heads/<name>`; блоки без `branch` — detached —
  пропускаются). `worktreeForBranch` переписывается через неё.
- Переключение ветки в корне — существующий `checkout(repo:branch:)`
  (новый метод не нужен).
- `createBranch(_ repo: String, _ branch: String, base: String) throws` —
  `git -C <repo> checkout -b <branch> <base>`; существующая ветка/плохой
  base → `GitError`.

### CreateService (`/covey/Sources/CoveydCore/CreateService.swift`)

- `.checkout(branch)`:
  - `worktreeForBranch` нашёл путь → та же резолюция, что у `.existing`:
    корень → `Prepared(finalDir: repo, worktreeRepo: nil)`; linked
    worktree → `Prepared(finalDir: path, worktreeRepo: repo)`;
  - иначе `GitOps.checkoutBranch` → `Prepared(finalDir: repo,
    worktreeRepo: nil)`.
- `.checkoutNew(branch, base)`: `validateBranch` →
  `GitOps.createBranch` → `Prepared(finalDir: repo, worktreeRepo: nil)`.
- `.new` / `.existing` — без изменений.

### IPCServer

- Обработчик `.gitInfo` дополнительно кладёт `GitOps.worktrees(repo)`
  (пустая карта для не-репо).

## 5. GUI

- **NewSessionSheet выносится** из `/covey/Sources/covey/Views/Sheets.swift`
  в `/covey/Sources/covey/Views/NewSessionSheet.swift` (файл разросся;
  остальные sheet'ы не трогаются).
- Удаляются: `useWorktree`-toggle, `branchChoice` cycleRow,
  `newBranchSlot`, TextField «New branch name», Base cycleRow.
- Новый переиспользуемый typeahead-ряд (private view/функция в
  NewSessionSheet.swift): TextField + suggestion-список; параметры —
  FormField, binding текста, список веток, placeholder, allowNew
  (branch — true, base — false). Suggestion-список — та же вёрстка, что у
  dirRow (выделение, кап 8, `… N more`, клик).
- Состояние: `branchInput`, `branchSelected`, `baseInput`,
  `baseSelected`; производные (isNew, worktreePath, showCheckbox,
  showBase) считаются из `branchInput` + данных `gitInfo`.
- `.task(id: dir)` дополнительно сохраняет `worktrees`; при смене dir
  текст поля сохраняется, производные пересчитываются.
- `FormField`: `.worktree` остаётся (теперь чекбокс «Create worktree»),
  `formFieldSequence` получает новую сигнатуру:
  `formFieldSequence(terminal:isRepo:showWorktreeToggle:showBase:isClaude:customAgent:)`
  с порядком `… .branch, [.worktree], [.base], …`.
- Submit: `branchPlan(...)` → `WorktreeSpec?` → `model.createFull` как
  сейчас; inline-ошибки без изменений.

## 6. Тесты

- **CoveyKitTests/CreateLogicTests**: матрица `branchPlan` (все 6 строк
  §2 + trim + пустой base-дефолт + detached current=nil),
  `filterBranches` (префикс, регистр, пустой query).
- **CoveyAppTests/DirBrowseTests**: новые кейсы `formFieldSequence`
  (isRepo без чекбокса, с чекбоксом, с base).
- **CoveydCoreTests/GitOpsTests** (настоящий temp-репо): `worktrees()` —
  только главный; главный + linked; detached пропускается; `createBranch`
  ok / дубликат → ошибка / плохой base → ошибка.
- **CoveydCoreTests/CreateServiceTests**: `.checkout` — три резолюции
  (текущая → корень без worktreeRepo; ветка в linked worktree → путь
  worktree; не checked out → switch в корне); `.checkoutNew` — ветка
  создана, HEAD на ней, finalDir = корень; ошибки прокидываются.
- **Протокол round-trip**: новые кейсы `WorktreeSpec`, `gitInfo` с
  `worktrees`.
- Форма — смоук (существующий).

## 7. Границы

- Переключение веток в уже живых сессиях — нет.
- Remote-ветки, fuzzy-фильтр — нет (префикс, как dir-пикер).
- cycleRow для agent/model/effort — не трогаем.
- Rename `WorktreeSpec` (теперь шире, чем worktree) — не делаем, чтобы не
  трогать протокол и планы слайса 15.
