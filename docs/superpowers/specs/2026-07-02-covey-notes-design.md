# Slice 13 — заметки: NoteModel, t/T в Inspector, счётчики, rename project (Design Spec)

> Дата: 2026-07-02
> Источник: порт `amux-core/note.rs` (чистая markdown-логика) и note-режима
> `amux-tui` (`NoteState` app.rs:762, `handle_note_key` app.rs:2660,
> `ui/note.rs`). Направление: `keyboard-first-priority`. Решение: панель
> заметок живёт в Inspector (терминал остаётся виден — плюс GUI над TUI).

## 0. Контекст

Inspector — плейсхолдер; поля `notes`/`projectNotes`/`projectNames` лежат в
схеме `state.json` мёртвым грузом со среза 5. Срез 13 оживляет их: заметки
сессий (`t`) и проектов (`T`) с markdown-чекбоксами, счётчики done/total на
карточках и заголовках групп, display-имена проектов (`space s R`).

## 1. NoteModel — чистый порт note.rs

Новый `/covey/Sources/covey/NoteModel.swift`, семантика 1:1 с Rust
(файл `crates/amux-core/src/note.rs` — ground truth):

```swift
enum NoteLine: Equatable {
    case task(done: Bool, text: String)   // "- [ ] text" / "- [x] text" (x|X)
    case heading(level: Int, text: String) // "#"…"######", level капится 6
    case bullet(String)                    // "- text" / "* text", не-таск
    case text(String)                      // прочие непустые строки (как есть)
    case blank                             // пустая строка
}

func parseTask(_ line: String) -> (done: Bool, text: String)?  // строгий "- [ ]"/"- [x]",
                                                               // ведущие пробелы ок
func parseNote(_ buf: String) -> [NoteLine]                    // split "\n"
func taskCounts(_ buf: String) -> (done: Int, total: Int)
func taskLineIndices(_ buf: String) -> [Int]                   // ординал таска → номер строки
func toggleTask(_ buf: String, ordinal: Int) -> String         // [ ]↔[x], сохраняет отступ
func removeTasks(_ buf: String, ordinals: Set<Int>) -> String  // удаляет строки тасков
func selectedAsNumbered(_ buf: String, ordinals: [Int]) -> String // "1. text\n2. text"
```

Отличие от Rust только в подписи: функции возвращают новую строку вместо
`&mut` (Swift-идиома). Все — без IO, табличные тесты повторяют кейсы note.rs.

## 2. Состояние

- **Персист** (поля уже в `PersistedState`): `notes: [String: String]` (по
  имени сессии), `projectNotes: [String: String]` (по dir группы),
  `projectNames: [String: String]` (dir → display-имя). AppModel: загрузка в
  `start()`, запись в `persist()`, мутаторы `setNote(session:text:)`,
  `setProjectNote(dir:text:)`, `setProjectName(dir:name:)` (пустое имя
  удаляет override). Пустая заметка удаляет ключ.
- **Transient** (AppModel):
  - `enum NoteTarget: Equatable { case session(String), project(String) }`,
    `noteTarget: NoteTarget?` — что показывает Inspector;
  - `struct NoteUIState: Equatable { var cursor: Int = 0; var visualAnchor: Int?;
    var editing = false; var clearArmed = false }`, `noteState: NoteUIState`;
  - выделение = диапазон `min(anchor,cursor)...max(anchor,cursor)` по
    ординалам тасков (как в TUI).
- `InputMode` получает case `.note` — Render-фокус заметки. Edit-режим —
  first responder у `TextEditor` (NSTextView), монитор пропускает клавиши сам.

## 3. Клавиши

### Normal
| `t` | заметка выбранной сессии: открыть Inspector + фокус `.note`; повторный `t` на той же цели — закрыть (`noteTarget = nil`, режим normal) |
| `T` | то же для заметки проекта выбранной сессии |

Открытие включает `showInspector` (персистится как обычно). Без выбранной
сессии `t`/`T` — no-op.

### Note / Render (порт handle_note_key)
| `j`/`k`/`↓`/`↑` | курсор по ординалам тасков |
| `Space` | тоггл чекбокса курсора (или всех в выделении) |
| `V` | вкл/выкл visual-выделение (якорь = курсор) |
| `y` | копировать выделение (или курсор) как нумерованный список в NSPasteboard; выделение снимается |
| `d` | удалить строки тасков выделения/курсора (без подтверждения) |
| `e` | Edit-режим (TextEditor, фокус в него) |
| `c` | armed-confirm очистки; следующий `y` — стереть заметку целиком, любая другая клавиша — отмена |
| `Tab` | расфокус: режим normal, заметка остаётся видна |
| `Esc` | снять выделение, если есть; иначе закрыть заметку (target=nil, normal) |

### Edit
`TextEditor` владеет вводом (guard монитора на NSTextView). Esc
(`.onExitCommand`; если для TextEditor не сработает — обёртка NSTextView с
`cancelOperation`, риск отмечен в плане) коммитит буфер → Render. Коммит
пишет через `setNote`/`setProjectNote`.

### Leader
`space s R` → новый `Modal.renameProject(dir)` — шит с TextField
(префилл текущим display-именем), пишет `projectNames`; пустая строка
сбрасывает override. Пункт в which-key белеет.

## 4. UI

- **InspectorView**: `noteTarget != nil` → `NotePane`, иначе прежний
  плейсхолдер.
- **NotePane**: заголовок `{title}  {done}/{total}  {hint}` (title: имя
  сессии или display-имя проекта; hint по под-режиму: `e edit · space toggle ·
  esc close` / `esc done`); тело Render: строки NoteLine — таски `☐`/`☑`
  (done — dim + strikethrough), курсор `›`, подсветка выделения, заголовки
  жирным, буллеты `•`; тело Edit: `TextEditor` с моноширинным сырым markdown.
- **Карточки сессий**: при непустой заметке — `done/total` в строке агента.
- **Заголовки групп**: display-имя из `projectNames` (fallback — прежний
  dir) + `done/total` проектной заметки при наличии.
- Мышь вторична, но работает: клик по таску ставит курсор, клик по чекбоксу
  тогглит, кнопка Edit в заголовке панели.
- StatusBar: режим `.note` → индикатор `NOTE`, подсказки
  `space toggle · e edit · d delete · V select · y yank · esc close`.

## 5. Router

Новые `KeyAction`: `toggleSessionNote`, `toggleProjectNote`,
`noteCursor(down: Bool)`, `noteToggleTask`, `noteVisual`, `noteYank`,
`noteDelete`, `noteEdit`, `noteArmClear` — маршрутизация:
- normal: `t`/`T` (латинизация действует);
- `.note`: таблица Render-клавиш; `y` → `.noteYank` всегда — armed-confirm
  интерпретирует `AppModel.apply` (роутер остаётся без состояния);
- leader `.session` + `R` → `renameProject` action.
Guard: `.note`-режим активен только при фокусе вне терминала (терминальная
ветвь роутера первична, как раньше).

## 6. Тесты

- **NoteModelTests**: порт кейсов note.rs — parseTask (строгость: `-[ ]` без
  пробела и `- [y]` — не таски), parse (heading уровни/кап 6, bullet `- `/`* `,
  blank), counts, toggle с отступом, removeTasks, selectedAsNumbered
  (перенумерация, неизвестные ординалы).
- **KeyRouterTests**: `t`/`T` в normal; таблица `.note`; `s R` в leader;
  кириллица (`е`→`t`).
- **AppModelChromeTests**: notes/projectNotes/projectNames персист+load;
  `apply(.toggleSessionNote)` открывает/закрывает и включает Inspector;
  тоггл-чекбокс через apply меняет markdown и counts; `d` удаляет; `c`+`y`
  чистит, `c`+прочее — нет; Esc-каскад (выделение→закрытие); renameProject
  через Modal.
- UI (NotePane, счётчики карточек) — смоук.

## 7. Границы

- Не в срезе: драфты и reply (`i`) — срез 14; project root по worktree
  (группировка остаётся по dir); markdown-рендер сверх NoteLine (ссылки,
  код) — text as-is.

## 8. Definition of Done

1. Сборка + полный набор тестов зелёные.
2. Смоук (клавиатура): `t` — заметка сессии в Inspector; набор тасков в `e`,
   Esc — Render; `Space` тогглит, счётчик на карточке обновляется и
   переживает перезапуск; `V`+`j`+`y` — в буфере нумерованный список; `d`
   удаляет; `c`+`y` чистит; `Esc` закрывает; `T` — проектная заметка,
   счётчик в заголовке группы; `space s R` — переименование проекта видно в
   заголовке и переживает перезапуск; повторный `t` закрывает.
3. Vim off: заметки доступны мышью (клики по чекбоксам, Edit-кнопка).
