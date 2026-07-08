# Слайс 31 — детали issue: пин шапки, MD-рендер, типографика (Design Spec)

> Детали issue: шапка закреплена, скроллится только описание; описание
> рендерится тем же markdown-механизмом, что превью заметок (один
> общий рендерер); шрифты issue-вью поднимаются на 2pt к ориентиру
> «текст вкладки agent» и собираются в одном месте для последующей
> подстройки. База: ветка `slice-28`.

## 1. Общий MD-рендерер

- Line-рендерер `render(_ line: NoteLine)` из `VimPreview`
  (/covey/Sources/covey/Views/VimEditor.swift:491) выносится в новый
  `Sources/covey/Views/MarkdownLine.swift`:
  `struct MarkdownLineView: View { let line: NoteLine; let tk: Tokens }`
  — тело switch переносится 1:1 (заголовки 15/13 bold/semibold,
  Obsidian-чекбоксы, буллеты, `.callout`-текст, blank).
- `VimPreview` использует `MarkdownLineView` внутри прежней обёртки
  (гуттер с номерами строк, подсветка строки курсора) — превью заметок
  не меняется визуально.
- `IssueDetailView` рендерит body:
  `ForEach(Array(parseNote(issue.body).enumerated()), id: \.offset)`
  → `MarkdownLineView(line:tk:)` — без гуттера и курсора, с
  `textSelection` не совместимо построчно — селекция текста описания
  опускается (рендер важнее; сырое тело доступно через `e`/браузер).
- Пустое body — прежний плейсхолдер «no description» (`tk.t4`).

## 2. Детали: закреплённая шапка

`IssueDetailView` перестраивается:

```
VStack(alignment: .leading, spacing: 8) {
    header   // #N + state-бейдж, заголовок, автор+дата, лейблы — БЕЗ скролла
    Divider()
    ScrollView { md-body }   // скроллится только описание
}
```

Шапка — прежний состав (номер, OPEN/CLOSED, заголовок selectable,
автор, дата, чипы лейблов). Футер-хинты панели уже вне вью — не
меняются.

## 3. Типографика issue-вью

Новый `Sources/covey/Views/IssueFonts.swift` — единая точка подстройки:

```swift
enum IssueFont {
    static let title: CGFloat = 15      // был .callout ~13 (титул деталей)
    static let body: CGFloat = 13       // был .caption ~11 (текст, заголовки карточек)
    static let meta: CGFloat = 12       // был .caption2 ~10-11 (мета, превью, чипы)
    static let mono: CGFloat = 15       // был 13 (#N карточки)
    static let monoSmall: CGFloat = 12  // был 10 (возраст, WIP-бейджи)
}
```

Все issue-вью переезжают на эти размеры (`.font(.system(size:
IssueFont.body))` и т.п.): IssueCardView (титул, превью, чипы, автор,
возраст, WIP), IssueDetailView (шапка, мета, чипы), IssueEditView
(лейблы, подписи), строки списка/пустые состояния/стейл-нота в
IssueBrowserPane. MD-тело деталей рендерится MarkdownLineView и живёт
на его собственных размерах (общих с превью заметок) — его не трогаем.
Ориентир — текст вкладки agent (~13pt mono); «потом скорректируем» =
крутим константы в одном файле.

## 4. Тесты

- Поведенческих изменений моделей нет — только вью. `swift test`
  зелёный (388/1/0), `parseNote` уже покрыт NoteModelTests.
- Руками: длинное описание скроллится под неподвижной шапкой; MD
  (заголовки/чекбоксы/буллеты) выглядит как превью заметки; размеры
  сопоставимы с терминалом agent.

## 5. Вне скоупа

- Инлайн-разметка (bold/links) — parseNote line-based, как в заметках.
- Селекция текста в отрендеренном body.
- Подстройка шрифтов сессионных карточек/заметок.
