# Slice 9 — хвосты: скролл в TUI + техдолг среза 2 (Design Spec)

> Дата: 2026-07-02
> Источник: находки отладки среза 8 (память `swiftterm-scroll-quirks`) +
> отложенные находки ревью среза 1/2 (память `slice2-deferred-review-findings`).
> Это спека **девятого среза** — без новых фич UI: чинит взаимодействие колеса
> мыши с TUI-агентами, залипание HISTORY и четыре пункта техдолга CoveydCore.

## 0. Контекст и корни

Отладка среза 8 выявила (все факты подтверждены headless-пробой и логом позиций):

1. **Колесо мертво в TUI-сессиях** (claude, vim, less): в alternate-буфере у
   SwiftTerm нет скроллбэка, а `scrollWheel` не пересылает колесо приложению
   ни как mouse-коды, ни как стрелки. DECSET 1007 (alternate scroll) SwiftTerm
   не поддерживает вовсе.
2. **HISTORY залипает при drag ползунка**: `scroll(toPosition:)` в SwiftTerm
   усекает `Int(maxScrollback * toPosition)` — drag «до упора» оставляет
   viewport на 1 строку выше дна, позиция ~0.9946 < порога 0.999, бейдж горит.
   Колесо доводит точно (`scrollDown` клампит к максимуму → честный 1.0).
3. **HISTORY может залипнуть при переключении буфера**: скролл шелла вверх →
   запуск TUI (alt-буфер) → события `scrolled` больше не приходят, флаг
   остаётся истинным.

Техдолг среза 2 (ещё открыт): #5 блокирующий `waitpid`, #6 дыры в авто-именах
`s-N`, #7 oversize-append в кольцевом буфере, #9 дубли кода.

## 1. CoveyTerminalView — сабкласс TerminalView

Новый файл `/covey/Sources/covey/CoveyTerminalView.swift`. Только public API
SwiftTerm (проверено: `TerminalView` — `open class`, `bufferActivated` —
`open func`, `isCurrentBufferAlternate`, `mouseMode`, `applicationCursor`,
`encodeButton`, `sendEvent`, `send(_ bytes:)`, `scroll(toPosition:)`,
`buffer.yDisp` — public). Без форка.

### 1.1 scrollWheel

```
если terminal.isCurrentBufferAlternate:
    если terminal.mouseMode.sendButtonPress():
        колесо → SGR wheel-события: encodeButton(button: 4|5) + sendEvent(x:y:)
        (col/row из точки события: bounds и terminal.cols/rows; точности
         до ячейки достаточно)
    иначе:
        колесо → стрелки Up/Down («alternate scroll» как в iTerm2/kitty);
        terminal.applicationCursor выбирает SS3 (ESC O A/B) vs CSI (ESC [ A/B);
        повторов = min(round(|deltaY|), 5) на событие, минимум 1;
        отправка через send(_ bytes:) — тот же путь, что клавиатура → PTY
иначе:
    super.scrollWheel — нынешний скролл viewport
```

`deltaY == 0` — ранний выход (как в super). `historyMode` в alt-ветках не
трогается: viewport не двигается, событий `scrolled` нет — корректно по
построению.

### 1.2 bufferActivated

Переопределить: вызвать `super`, затем колбэк `onBufferSwitch: (() -> Void)?`.
Coordinator подписывается и сбрасывает `model.setHistoryMode(false)` — закрывает
корень №3.

### 1.3 Интеграция

`TerminalController.makeNSView` создаёт `CoveyTerminalView` вместо
`TerminalView`. Остальной код Coordinator не меняется (делегат тот же).

## 2. Снап ползунка к дну

В `Coordinator.scrolled(source:position:)`: недолёт в одну строку вычисляется
без внутренностей SwiftTerm —

```
linesShort = round((1 - position) * yDisp / position)   // yDisp: buffer.yDisp (public)
если 0 < position < 1 и linesShort == 1:
    view.scroll(toPosition: 1.0)     // Int(max * 1.0) == max — точное дно
```

После снапа приходит честное `scrolled(1.0)` → `historyMode = false` штатным
путём. Порог ровно в одну строку: осознанный скролл на ≥2 строки вверх не
утягивается независимо от размера скроллбэка. Порог 0.999 в вычислении
`history` не меняется.

## 3. Техдолг CoveydCore

- **#5 `PTYProcess.reap`**: ЗАКРЫТО как не-баг (обнаружено при исполнении).
  Эмпирика: на macOS master получает EOF ровно в момент выхода session
  leader'а (tty revoke) — внук с открытыми fd слейва EOF не задерживает, а
  живой лидер с закрытыми fd EOF не даёт вовсе. `reap()` вызывается только по
  EOF ⇒ ребёнок уже зомби ⇒ блокирующий `waitpid` мгновенен. Вместо exit-source
  (недостижимый код): комментарий-инвариант в `reap()` + тест
  `testMasterEOFImpliesChildExited`, пинящий семантику в обе стороны.
- **#6 `SessionRegistry.counter`**: инкремент только когда авто-имя реально
  использовано (создание успешно и имя не задано явно) — `s-N` без дыр.
- **#7 `ScrollbackBuffer.append`**: кусок больше ёмкости кольца обрезается до
  последних `capacity` байт перед записью; возвращаемый диапазон не содержит
  уже вытесненного начала, `since(from)` не отдаёт мгновенный `gapped` на
  собственный результат.
- **#9 дубли**: `SessionRegistry.withProcess(name) { proc in … }` вместо ×4
  паттерна `lock; entries[name]?.process; unlock; proc?.…`; сборщик
  `expectOutput` из дублей в тестах → общий `TestSupport`.

## 3.1 Дополнение по итогам смоука: дедлок демона на застрявшем raw-ребёнке

Смоук выявил зависание всего демона: raw-режимный ребёнок перестаёт читать
tty → ядро не принимает ввод → блокирующий `write()` вешает pty-очередь →
`backfill` (`queue.sync`) с IPC-потока вешает весь демон, включая `kill()`.
Тот же класс отказа, что #5, но реальный. Фикс: master fd переведён в
`O_NONBLOCK`, невлезший ввод паркуется в ограниченный `pendingInput`
(переполнение отбрасывается, как в полной ядерной очереди) и доливается
write-source'ом; `ScrollbackBuffer` синхронизирован внутренне, `backfill`
больше не ходит через pty-очередь; read-петля терпит `EAGAIN`/`EINTR`.
Запинено тестом `testWriteToStuckChildDoesNotWedgeQueue`.

## 4. Тесты

XCTest, headless (паттерн пробы из отладки среза 8: `TerminalView` создаётся
без окна, делегат-запись). Без sleep; существующие хелперы.

- **CoveyTerminalViewTests** (новый, target CoveyAppTests):
  - alt-буфер + mouse-reporting: скормить `ESC [?1049h` + `ESC [?1000h`,
    послать `scrollWheel`-событие → в `delegate.send` приходят SGR wheel-коды
    (up и down различаются);
  - alt-буфер без mouse-reporting: приходят `CSI A`/`CSI B`; с
    `applicationCursor` (DECSET 1) — `SS3 A`/`SS3 B`; повторы капятся 5;
  - обычный буфер: wheel — события `scrolled` (viewport), в `send` ничего;
  - `bufferActivated`: вход/выход alt-буфера дёргает `onBufferSwitch`.
- **Снап**: feed 200 строк → `scroll(toPosition: 0.997)` (репро усечения —
  недолёт в 1 строку) → логика Coordinator доводит до `1.0`; недолёт в 2+
  строки не трогается.
- **CoveydCoreTests**: reap не блокирует очередь (ребёнок-«живучка», ловящий
  SIGHUP: kill возвращается сразу, очередь отвечает до истечения эскалации);
  `s-N` подряд после дубля имени и после явного имени; oversize-append:
  `append(байт > capacity)` → `since(from)` отдаёт валидный диапазон без gap;
  `withProcess`/`expectOutput` — рефактор под существующими тестами (зелёные).
- Полный набор — 0 падений.

## 5. Границы среза

- Не трогаем: протокол IPC, AppModel, SwiftUI-виды, NewSessionSheet.
- Форк/PR в SwiftTerm — вне среза (кандидат: rounding в `scroll(toPosition:)`,
  DECSET 1007).
- Скролл-момент (инерция трекпада) в alt-ветках не эмулируется — по событию.

## 6. Definition of Done

1. Сборка + полный набор тестов зелёные (включая новые CoveyTerminalViewTests).
2. Смоук: в claude-сессии колесо скроллит чат claude; в `less` — колесо
   листает; в шелле — viewport как раньше.
3. Drag ползунка до упора вниз гасит HISTORY.
4. Скролл шелла вверх → запуск `vim`/`less` → HISTORY гаснет сам.
5. Kill сессии с ребёнком, игнорирующим SIGHUP, не подвешивает демона.
6. Авто-имена `s-N` идут подряд; oversize-append не ломает `since`.
