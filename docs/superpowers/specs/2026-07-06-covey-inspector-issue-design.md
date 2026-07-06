# Слайс 25 — инспектор Note/Issue, драфты, window-чорды (Design Spec)

> Issue-композер переезжает из модалки в правую шторку и живёт рядом с
> note: зонные табы Note/Issue, режим сплита, черновик per-project,
> клавиатурные чорды с подсказками в футере шторки. Плюс leader-группа
> `space w` для скрытия панелей. GUI-only.

## 1. Инспектор: табы и режимы

- Header инспектора — зонная полоска в стиле Session/Agent/Terminal:
  табы `Note` и `Issue` (font 10 semibold; активный — `tk.accent`,
  неактивный — `tk.t4`; клик переключает). Имя сессии/проекта из
  header уезжает в тело Note-таба (мелкая строка + счётчик тасков).
- `AppModel.inspectorTab: .note/.issue` (не персистится),
  `inspectorSplit: Bool` (персист: `PersistedState.inspectorSplit`).
- Режимы:
  - **tabs** — виден один таб;
  - **vsplit** — note сверху, issue снизу (50/50, без перетаскивания —
    YAGNI), «пишешь issue, глядя в заметку». Автопереноса текста нет.
- Тогл режима: `s` при фокусе в инспекторе и НЕ в редакторе/поле
  (роутится через существующий note-режим/инспектор-контекст).
- Плейсхолдер «Inspector» остаётся, когда нет ни noteTarget, ни
  выбранной сессии для issue.

## 2. Чорды зоны inspector

Когда `focus == .inspector`, локальный контекст перекрывает глобальные
значения:

- `⌃h` / `⌃l` — переключение таба Note↔Issue (tabs-режим; в сплите —
  no-op).
- `⌃j` / `⌃k` — в сплите фокус между панелями note↔issue (в
  tabs-режиме — no-op).
- Выход из зоны — Esc (существующее поведение note) или `⌃\`-семейство
  не трогаем.
- Роутинг: KeyRouter получает контекст «inspector zone» (focus ==
  .inspector) и мапит эти чорды в новые KeyAction
  (`inspectorTabNext/Prev`, `inspectorPaneToggle`); вне зоны ⌃h/l/j/k
  работают как раньше (cycle zones / scroll).

## 3. Vim-бейдж и иконки

- Правый нижний угол шторки: бейдж `INSERT` (когда редактируется note
  или фокус в title/body issue) / `NORMAL` (иначе) — мелкий, стиль
  amux-статуса (semibold caption, `tk.warn` для INSERT, `tk.t4` для
  NORMAL).
- NotePane: кнопка «Edit» → SF-иконка `pencil`; «Done» → SF-иконка
  `square.and.arrow.down` (сохранение). Поведение прежнее.

## 4. Issue-форма (в шторке)

- Поля: Title (AyuField), Body (TextEditor в ayu-рамке, ~10 строк в
  tabs-режиме, тянется в сплите), чекбокс «Assign to me» (глиф как в
  форме создания; заглавная A).
- Клавиши: `Enter` в Title — submit; `Tab` — Title↔Body; Enter в
  Body — перенос строки; `⌘ M` — тогл Assign to me; `⌘ O` — Open in
  browser; Esc в поле — снять фокус с поля (зона остаётся).
  ⌘-чорды — через `.keyboardShortcut` на кнопках (работают поверх
  текстовых полей главного окна).
- Кнопки: `Create` (glassProminent, disabled при пустом title),
  `Open in browser…`, чекбокс. Подсказки — футером шторки: kbd-бейджи
  в формате с пробелом «⌘ M», «⌘ O», «enter» + подписи (стиль kbd из
  StatusBar).
- Стадии creating / ✓ done(URL, клипборд) / ✕ failed(err) — в теле
  Issue-таба; поведение и тексты из слайса 24 сохраняются. Esc во
  время creating — можно уйти из шторки, gh дорабатывает, тост.
- `--web`: gh кодирует title/body/assignee в URL — браузер открывается
  с заполненными полями; локальный драфт НЕ стирается.
- `space g i`: гарды прежние («no session», «not a git repo»), успех —
  `showInspector = true`, `inspectorTab = .issue`, фокус в Title.
  `Modal.issue`, `IssueSheet` и их тесты-вязки удаляются
  (IssueService/parseIssueURL/issueCreateArgs остаются как есть).

## 5. Черновик per-project

- `IssueDraft { title, body, assignMe }: Codable` в
  `PersistedState.issueDrafts: [String: IssueDraft]?` — ключ:
  `sessionRoot` сессии (worktree-сессии делят драфт с корнем проекта).
- Автосохранение: onChange полей → модель → debounced persist
  (существующий StateStore-механизм).
- Успешный create (не --web) чистит драфт проекта. --web и Esc драфт
  сохраняют.
- Открытие Issue-таба загружает драфт проекта выбранной сессии; смена
  выбранной сессии на другой проект — перезагрузка драфта.

## 6. `space w` — window-группа

Leader-группа для панелей (тоглы уже существуют в AppModel + persist):

- `space w s` — показать/скрыть список сессий (`setShowSessions`);
- `space w i` — инспектор (`setShowInspector`);
- `space w f` — footer (`setShowFooter`);
- `space w h` — header (`setShowHeader`).
- Which-key root: строка `w — window: sessions · inspector · footer ·
  header`; подгруппа с четырьмя пунктами. HelpOverlay дополняется.
- Гард: скрытие инспектора при фокусе в нём возвращает фокус в
  sessions-зону.

## 7. Тесты

- KeyRouter: `space w s/i/f/h` → новые KeyAction; `⌃h/⌃l/⌃j/⌃k` в
  inspector-фокусе → inspector-экшены, вне его — прежние.
- AppModel: `space g i` открывает инспектор с Issue-табом (модалки
  нет); тогл `s` меняет `inspectorSplit` и персистится; window-тоглы
  меняют show-флаги; скрытие инспектора из его зоны переводит фокус.
- PersistedState: `issueDrafts` round-trip.
- Драфт: setIssueDraft/загрузка по sessionRoot, очистка после
  успешного create (через модельный хук, gh в тестах не зовём).
- Существующие IssueService-тесты не меняются.

## 8. Смоук (user)

Рестарт демона не нужен.

1. `space g i` на сессии в репо — открылась правая шторка, таб Issue,
   курсор в Title. Табы Note/Issue в header, стиль зонных.
2. Заполнить title/body, `⌘ M` — галка Assign to me; уйти в код
   (⌃h/⌃l по зонам), вернуться — драфт на месте; перезапуск GUI —
   драфт жив.
3. `Enter` в Title — creating → done, URL в клипборде; драфт очищен.
4. `⌘ O` — браузер с заполненными полями; локальный драфт остался.
5. `s` в инспекторе — сплит note+issue; `⌃j/⌃k` ходит между панелями;
   `s` — обратно в табы, `⌃h/⌃l` переключает Note↔Issue.
6. Note: карандаш/дискета вместо Edit/Done; при редактировании справа
   внизу INSERT, вне — NORMAL.
7. `space w s/i/f/h` — панели прячутся/показываются; футер с
   kbd-подсказками «⌘ M» — с пробелом.
