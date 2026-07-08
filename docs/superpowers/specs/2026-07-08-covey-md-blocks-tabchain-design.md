# Слайс 32 — MD-блоки, высота редактора, Tab к лейблам (Design Spec)

> Общий markdown-рендерер получает основные блоки (жирный/курсив/mono
> инлайн, разделитель, цитаты, код-фенсы); body-редактор issue растёт
> до половины шторки; Tab/Shift-Tab включают лейблы в фокус-цикл формы
> (сейчас цепочка замкнута title↔body — направление игнорируется).
> База: ветка `slice-28`.

## 1. Markdown: блоки и инлайн

**Жёсткий инвариант:** `parseNote` выдаёт ровно один `NoteLine` на
строку входа — превью заметок мапит строки на курсор 1:1.

- `NoteLine` расширяется: `.rule` (строка из ≥3 `-`/`*`/`_` без иного
  текста), `.quote(String)` (`> ` префикс, маркер срезан),
  `.codeFence` (строка-маркер ```), `.code(String)` (строка внутри
  фенса, сырая).
- `parseNote` становится стейтфул-циклом (флаг inFence): внутри фенса
  каждая строка → `.code`, маркеры → `.codeFence`. Снаружи — прежние
  правила + rule/quote. `parseLine` остаётся для внефенсовых строк.
- `MarkdownLineView` рендер: `.rule` — тонкая линия `tk.bd2` на всю
  ширину (высота 1, вертикальные отступы 4); `.quote` — вертикальная
  полоска `tk.t4` слева + текст `tk.t3`; `.codeFence` — пустой
  спейсер высотой 2 (маркеры не показываем, фенс читается по подложке
  кода); `.code` — mono-текст (13) на подложке `tk.surf2` во всю
  ширину строки.
- Инлайн-стили для heading/task/bullet/text/quote: текст прогоняется
  через `AttributedString(markdown:, options:
  .inlineOnlyPreservingWhitespace)` — даёт **bold**, *italic*,
  `inline code` (mono), [ссылки]. Ошибка парсинга → сырая строка.
  Хелпер `inlineMD(_ s: String) -> AttributedString` в
  MarkdownLine.swift.
- Заметки и issue получают апгрейд одновременно (рендерер общий) —
  это желаемое поведение.
- Тесты NoteModelTests: rule/quote/fence/code кейсы + 1:1 инвариант
  (`parseNote(буфер из N строк).count == N` с фенсами), таск-парсер
  не задет.

## 2. Высота body-редактора

Экран edit (IssueEditView) оборачивается в GeometryReader; VimEditor
получает `.frame(height: geo.size.height * 0.5)` вместо фикс. 120.
Чеклист лейблов сохраняет `maxHeight: 90` со скроллом.

## 3. Tab-цикл формы редактирования

Полный цикл: title →Tab→ body →Tab→ label[0] →Tab→ … →Tab→ последний
label →Tab→ title; Shift-Tab — обратный ход (label[0] →⇧Tab→ body,
body →⇧Tab→ title, title →⇧Tab→ последний label — опционально, если
дёшево; минимум: title ⇧Tab не ломается).

- `onSwitchField(forward)` в IssueEditView начинает уважать
  направление: `true` → фокус в первый лейбл (лейблов нет → title);
  `false` → title.
- `handleLabelKey`: Tab → следующий лейбл / с последнего → title;
  Shift-Tab → предыдущий / с первого → body. Фокус в body — через
  существующий `focusTick` VimEditor (`@State editorFocusTick`,
  передаётся в VimEditor, бамп = захват клавиатуры редактором).
- Space/←/→/j/k/↓/↑ на лейблах — как есть (работают).

## 4. Тесты

- parseNote: новые кейсы + 1:1 инвариант (юнит).
- inlineMD: bold/code рендер-строки — юнит на AttributedString
  (runs с inlinePresentationIntent).
- Tab-цепочка и высота — руками (вью-механика).

## 5. Вне скоупа

- Таблицы, картинки, вложенные списки, подсветка синтаксиса в фенсах.
- Селекция текста в отрендеренном MD.
- Тач-ап композера (у него body без лейблов — цепочка прежняя).
