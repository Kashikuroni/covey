# Слайс 19 — дизайн-токены + карточный список сессий (Design Spec)

> Порт дизайн-системы amux-desktop (`crates/amux-desktop/assets/style.css`,
> `:root` + `.app.light`) в Swift и переделка списка сессий на карточки
> «варианта A» (утверждён в визуальном компаньоне: борт + тень +
> статус-полоска). Остальной хром (topbar, statusbar, inspector) — следующие
> срезы на этих же токенах.

## 1. Токены — `/covey/Sources/covey/Tokens.swift`

Новый файл; единственный источник цветов/радиусов/теней для SwiftUI-слоя.
Существующий `Theme.swift` (NSColor для SwiftTerm) не трогаем — терминальная
палитра отдельная; `Tokens` параметризуется тем же `Theme`.

```swift
struct Tokens {
    let theme: Theme
    // Поверхности: bg, surface, surf2, surf3, surf4, card, cardHover, termBg
    // Борта: bd (.07), bd2 (.13), bd3 (.22) — white-alpha в dark,
    //        slate-alpha в light (значения из style.css)
    // Текст: t1, t2, t3, t4
    // Статусы: run, wait, idle, ok, err, warn
    // Диффы: diffAdd, diffDel
    // Радиусы: r = 6, rSm = 4, rLg = 10
    // Тень карточки: sh (y2 blur8 black45 + y1 blur2 black30 — первая
    //   компонента; SwiftUI-shadow один, берём главную)
}
```

Значения — 1:1 из `style.css` (dark из `:root`, light из `.app.light`),
хексы переносятся точно (`#1C1917`, `#E8926A`, …). Инициализатор Color из
хекса — маленький private-хелпер там же.

## 2. Карточка сессии (вариант A) — `/covey/Sources/covey/Views/SessionListView.swift`

Переделка `row(_:)` и обвязки списка:

- **Карточка**: фон `card` (выбранная — `cardHover`), борт `bd`
  (выбранная — `bd3`), радиус `r`, тень `sh`; вертикальные отступы между
  карточками ~5, горизонтальные ~8 (как `.sr`).
- **Статус-полоска** слева (2px, скругление 2, отступы сверху/снизу 8):
  выбранная — `t1`, waiting — `wait`, иначе прозрачная.
- **Строка 1**: номер строки (mono 10, `t4`, ширина ~13, вправо) — номер из
  видимого порядка (тот же, что `selectByNumber`); точка статуса 6×6
  (running — `run` с glow-тенью, waiting — `wait`, idle — `idle` с бортом
  `bd2`); имя (mono 13 medium, `t2`; выбранная → `t1`, waiting → `wait`);
  счётчик задач заметки (как сейчас, `t4`); справа — статусный лейбл
  (mono 11: running/waiting/idle в цветах статуса, idle — `t4`).
- **Строка 2** (отступ слева 19): агент (mono 11 `t3`), ветка
  (`⎇`/`⧉` + имя, mono 11 `t3`), справа дифф `+N`/`−N`
  (`diffAdd`/`diffDel` с прозрачностью ~0.65). Returnable-бейдж
  (`⧉ worktree removed …`) занимает место строки 2, как сейчас.
- **Промпт-кнопки** — как есть (glass, слайс 18), под строкой 2.
- **Заголовок проекта**: имя КАПСОМ (11 semibold, `t4`, letterspacing
  ~0.07em) + справа meta `running/total` по проекту (mono 11 `t4`);
  счётчик задач проектной заметки — как сейчас.
- **Хром List**: системную подсветку выделения выключить — выделение
  рисует карточка (`.listRowBackground(Color.clear)` + plain-стиль,
  разделители скрыть). Drag-перестановка (`onMove`) и contextMenu
  сохраняются.

## 3. Recent-строки + возраст

- `RecentSession` (`/covey/Sources/CoveyKit/PersistedState.swift`)
  + `stoppedAt: Int64?` (optional Codable — старые записи декодятся);
  `pushRecent`-вызовы в AppModel заполняют текущим временем.
- `humanizeAge(_ secs: Int64) -> String` — порт `timeutil.rs`
  (`<60 → Ns`, `<3600 → Nm`, `<86400 → Nh`, иначе `Nd`; отрицательное → 0s):
  в CoveyKit рядом с моделью (чистая, тестируемая).
- Строка Recent (`rr`): `↻` `t4`; имя mono 13 `t3`; мета — агент + путь
  (как сейчас, `t4`/caption); справа возраст `humanizeAge(now − stoppedAt)`
  (mono 11, `t4`; нет `stoppedAt` — возраст не показывается); кнопка
  Relaunch остаётся.

## 4. Границы

- Topbar, statusbar, inspector, sheets, терминальная палитра — не в этом
  срезе (перекрасятся следующими на тех же токенах).
- `verified`-статус, `sr-goal` (двухстрочная цель) — не портируем
  (verify вне scope; цель у нас заменяют счётчики заметок).
- Hover-состояния карточек — только если тривиально в SwiftUI List
  (`onHover` не городить ради тени).
- Light-тема: токены портируются обе; переключение уже существует.

## 5. Тесты

- **CoveyKitTests**: `humanizeAge` (порт-кейсы: 0s, 59s, 60→1m, 3599→59m,
  3600→1h, 86399→23h, 86400→1d, отрицательное→0s); round-trip
  `RecentSession` со `stoppedAt` и без (старый payload декодится в nil).
- **CoveyAppTests**: спот-чек `Tokens` (dark.bg == #1C1917,
  light.card == #FFFFFF, радиусы 6/4/10) — фиксирует, что порт не
  разъехался при правках.
- Список — визуальный смоук: карточки, полоска на waiting/selected, glow
  running-точки, номера, дифф, заголовки проектов, Recent с возрастом,
  drag-перестановка и `selectByNumber` работают, light-тема читаема.
