# Слайс 18 — Liquid Glass: плавающий слой и кнопки (Design Spec)

> Точечное внедрение материала Liquid Glass (macOS 26) в кастомные
> поверхности covey. Дизайн утверждён в визуальном компаньоне
> (`.superpowers/brainstorm/`): объём — «оверлеи + кнопки», primary в
> sheet'ах — prominent. Системные поверхности (sheets, меню) получают новый
> вид от SDK автоматически — их не трогаем.

## 1. Принципы

- Стекло — только ПЛАВАЮЩИЙ слой над живым контентом (терминал, список).
- Стекло-в-стекле не делаем: содержимое sheet'ов (поля, списки, тексты)
  остаётся системным; стеклится только выделенная primary-кнопка.
- Терминал (SwiftTerm), список сессий, поля ввода, suggestion-списки формы —
  без изменений.
- Reduce Transparency обрабатывается системой, руками ничего не делаем.

## 2. Изменения

### Оверлеи → `.glassEffect`

| Файл | Сейчас | Становится |
|---|---|---|
| `/covey/Sources/covey/Views/WhichKeyView.swift:59` | `.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))` | `.glassEffect(.regular, in: .rect(cornerRadius: 8))` |
| `/covey/Sources/covey/Views/HelpOverlay.swift:53` | `.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))` | `.glassEffect(.regular, in: .rect(cornerRadius: 10))` |
| `/covey/Sources/covey/Views/ContentView.swift:153` (toastBar) | `.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))` | `.glassEffect(.regular, in: .rect(cornerRadius: 8))` |
| `/covey/Sources/covey/Views/UsageChip.swift:40` | `.background(.quaternary, in: Capsule())` | `.glassEffect()` (капсула — форма по умолчанию) |

### Кнопки

- **Промпт-ответы на карточках** (`SessionListView.swift:144`,
  кнопки `1 yes` / `2 no` / …): `.buttonStyle(.bordered)` →
  `.buttonStyle(.glass)`; `controlSize(.mini)` остаётся.
- **Primary-кнопки sheet'ов** → `.buttonStyle(.glassProminent)`:
  - Sheets.swift: Kill, Promote, Restart (одиночный), «Restart all»,
    Rename, RenameProject, DeleteBranch, Cleanup — кнопка действия
    (та, что с `keyboardShortcut(.defaultAction)`, у RestartAll — без);
  - NewSessionSheet.swift: Create.
  - Cancel-кнопки везде остаются дефолтными.
  - Деструктивные (Kill, DeleteBranch) сохраняют `role: .destructive` —
    prominent-стекло возьмёт красный оттенок от роли.

## 3. Тесты и проверка

- Стили — не юнит-тестируемы; гейт: `swift build` + полная сюита зелёная
  (регрессий нет) + смоук глазами:
  1. `space` → which-key парит стеклом над терминалом с бегущим выводом;
  2. `?` → help-оверлей стеклянный;
  3. toast (например, ошибка git-операции) — glass-капсула снизу;
  4. usage-чип в заголовке терминала — стеклянная капсула;
  5. карточка с промптом — стеклянные кнопки 1/2/3, клик работает;
  6. Kill-sheet: «Kill» — красный prominent, «Cancel» — обычная;
     NewSession: «Create» — акцентный prominent;
  7. System Settings → Accessibility → Reduce Transparency: всё читаемо.

## 4. Границы

- Морфы (`GlassEffectContainer`/`glassEffectID`) — нет: наши оверлеи не
  перетекают друг в друга; YAGNI.
- Тинты (`.tint(.orange)`, `.interactive()`) — нет, дефолтный материал;
  вернёмся, если после смоука стекло будет теряться на фоне.
- Список сессий, терминальная панель, chrome окна — без изменений.
- Fallback на старые macOS — не нужен (таргет проекта: macOS 26).
