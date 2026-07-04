# Слайс 23 — Recent-модалка (Design Spec)

> Recent уезжает из NewSessionSheet в собственную модалку на клавише
> `r`: карточки в стиле списка сессий, `/`-фильтр, j/k, Enter — рестор.
> GUI-only, демон/протокол не меняются.

## 1. Разделение New / Recent

- `NewSessionSheet`: удалить `SheetTab`, `Picker` New/Recent,
  `recentTab`, `relaunch(_:)`, состояния `sheetTab`/`recentIdx`/
  `recentFocused`. Остаётся только форма создания.
- `AppModel.Modal` + кейс `recent`; `ContentView` sheet-switch + кейс
  `RecentSheet(model: model)`.

## 2. Клавиши

- `KeyAction.openRecent`; `routeNormal`: `case "r": return .openRecent`.
- `apply(.openRecent)`: `inputMode = .normal; modal = .recent`
  (работает и при пустом списке сессий — модалка нужна как раз тогда).
- StatusBar hints (normal, vim): + `("r", "recent")`.
- HelpOverlay, группа act: + `("r", "recent sessions")`.

## 3. RecentSheet (Sheets.swift)

Данные: `model.visibleRecents()` (живые имена скрыты, максимум 20).

### Карточка (стиль SessionListView.card)

- `AgentIcon(agent:tk:)` + имя (mono 13 medium) + `⟳` (mono 11, tk.t4),
  если `resumeCmd != nil` — рестор продолжит разговор claude.
- Вторая строка: dir через `collapseHome` (mono 11, tk.t3).
- Справа: возраст `humanizeAge(now - stoppedAt)` (mono 11, tk.t4);
  `stoppedAt == nil` — пусто.
- Курсорная карточка: фон `tk.cardHover`, полоска слева `tk.t1`
  (как selected в списке сессий).

### Поведение

- Курсор: `j`/`k`/`↓`/`↑` (латинизация как везде — onKeyPress по
  символам после `latinize` не требуется: шит использует локальные
  `onKeyPress`, как NewSessionSheet/CleanupSheet — принять и кириллицу
  через `latinize` в хендлере).
- `/` — показывается строка фильтра внизу шита, фокус в ней;
  фильтрация `filterRecents(recents, filter)`; Esc в фильтре — очистить
  строку и вернуть фокус списку; Enter в фильтре — рестор курсорной.
- `Enter` (в списке) — рестор курсорной; клик мышью по карточке — тоже.
- Рестор = `model.relaunchRecent(r)` (уже селектит сессию и фокусит её
  терминал) + `model.modal = nil`.
- `Esc` (в списке) — закрыть модалку.
- Пусто (с учётом фильтра) — «no recently-stopped sessions».
- Курсор клампится при изменении фильтра (не выпадает за края).

### filterRecents (чистая, `Sources/covey/Fuzzy.swift` рядом с fuzzyMatch)

```swift
func filterRecents(_ recents: [RecentSession], filter: String) -> [RecentSession]
```

- Пустой фильтр — всё как есть (порядок recents сохраняется).
- Иначе `fuzzyMatch(filter, name) || fuzzyMatch(filter, dir)`.

## 4. Тесты

- KeyRouterTests: `r` в normal → `.openRecent`; `r` в terminal-фокусе
  НЕ перехватывается (уходит агенту).
- AppModel-тест: `apply(.openRecent)` → `modal == .recent`.
- `filterRecents`: пустой фильтр, матч по имени, матч по dir, без
  совпадений.

## 5. Смоук (user)

Рестарт демона не нужен.

1. `r` из списка — модалка Recent; карточки: иконка, имя, ~путь,
   возраст, ⟳ у claude-сессий.
2. `j/k` ходят, `Enter` — сессия ожила, модалка закрыта, фокус в её
   терминале.
3. `/` + текст — список сузился (по имени и по пути), Esc — фильтр
   снялся; Enter из фильтра — рестор.
4. Esc — закрылась. В NewSessionSheet (`n`) таба Recent больше нет.
5. Мышь: клик по карточке — рестор.
