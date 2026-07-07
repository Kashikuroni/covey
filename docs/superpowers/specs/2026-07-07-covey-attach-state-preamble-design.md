# Attach state-preamble — восстановление режимов терминала (Design Spec)

> После рестарта GUI attach реплеит хвост сырого ring-буфера в свежий
> SwiftTerm, но одноразовые DECSET-последовательности начала сессии
> (`?1049h`, mouse tracking) давно вытеснены из ринга. GUI-терминал
> остаётся в normal buffer → колесо роутится в `.viewport` и скроллит
> «кашу» из сырых кадров TUI. Фикс: демон при attach синтезирует
> преамбулу режимов из живого состояния ScreenModel и префиксует её к
> backfill, затем шлёт SIGWINCH для полной перерисовки. Daemon-only,
> протокол и GUI не меняются.

## 0. Контекст (диагноз)

- Оба пейна (Agent/Terminal) — один `CoveyTerminalView`; разница в
  состоянии эмулятора: claude = alt buffer + mouse tracking, shell =
  normal buffer.
- `AppModel.attachPane` всегда делает `attach(name, sinceSeq: 0)` в
  свежий `TerminalView` (remount по `.id`); демон отвечает сырым
  хвостом `ScrollbackBuffer` (1 MB ring).
- `?1049h` и `?1000h/1002h/1003h/1006h` claude шлёт один раз на старте
  процесса → в длинной сессии вытеснены → после рестарта GUI
  `isCurrentBufferAlternate == false` → `wheelRoute() == .viewport` →
  скролл по scrollback из обрывков кадров («каша»).
- Отдельное, НЕ чинимое здесь: живой claude игнорирует SGR-репорты
  колеса в главном чате (биндинг `wheelup` есть только в контексте
  `Scroll` — оверлей `ctrl+o`, диалоги). Проверено pty-пробами на
  2.1.201. Covey доставляет байты корректно.

## 1. Поток данных

```
attach(name, sinceSeq)                         // протокол прежний
  preamble = ScreenModel.statePreamble()       // DECSET из живого состояния
  bf       = ScrollbackBuffer.since(seq)
  event: output(name, seq: bf.fromSeq, preamble + bf.bytes)  // одно событие
  PTYProcess.kick()                            // SIGWINCH → полный кадр
```

- Преамбула ставит свежий GUI-эмулятор в состояние реального терминала
  сессии ДО парсинга хвоста: alt buffer активен → кадры рендерятся в
  alt, normal-buffer scrollback не засоряется, `wheelRoute()` снова
  даёт `.mouseReport`/`.arrows`.
- SIGWINCH заставляет TUI (claude, vim) перерисовать полный кадр —
  первый экран после рестарта целый, а не рваный хвост backfill.

## 2. Компоненты

1. **`ScreenModel.statePreamble() -> [UInt8]`** (CoveydCore) — под
   существующим lock читает публичное состояние `Terminal`:
   - `isCurrentBufferAlternate` → `ESC[?1049h`;
   - `mouseMode`: `.x10` → `?9h`, `.vt200` → `?1000h`,
     `.buttonEventTracking` → `?1002h`, `.anyEvent` → `?1003h`
     (vt200Highlight/declocator SwiftTerm не поддерживает — кейсов
     нет); при любом ≠ `.off` дополнительно
     `?1006h` (протокол мыши допускаем SGR — верно для
     claude/vim/lazygit; `mouseProtocol` в SwiftTerm приватен);
   - `bracketedPasteMode` → `?2004h`;
   - `applicationCursor` → `?1h` (DECCKM).
   Всё выключено → пустой массив. Порядок: `1049h` первым.
2. **`PTYProcess.kick()`** — `queue.async { Darwin.kill(-pid,
   SIGWINCH) }` с теми же guard'ами, что `kill()` (pid > 0, !reaped).
   `TIOCSWINSZ` того же размера сигнал не шлёт — потому явный kill.
3. **`SessionRegistry.statePreamble(name:) -> [UInt8]?` и
   `.kick(name:)`** — обёртки через `withEntry`.
4. **`IPCServer`, хендлер `.attach`** — префикс преамбулы к
   backfill-байтам; событие шлётся, если `preamble + bytes` непусто;
   `kick` после постановки backfill в очередь. Существующий порядок
   «backfill → attachOutputFanout» не меняется.

## 3. Границы и edge-кейсы

- Преамбула шлётся на **каждый** attach. Контракт GUI: attach всегда
  в свежесозданный `TerminalView`, повторный вход в alt безопасен.
- Свежая сессия (пустой ring, режимы off) — пустая преамбула, пустой
  backfill → событие не шлётся (текущее поведение).
- Хвост backfill может сам содержать `?1049h/l` — идемпотентно;
  транзиентные глитчи закрывает SIGWINCH-перерисовка.
- Не восстанавливаем: `cursorHidden` (claude мигает `?25h/l` каждый
  кадр), точный протокол мыши (допущение SGR), kitty keyboard flags
  (SwiftTerm не поддерживает), `applicationKeypad`. Самокорректируется
  или не влияет.
- SIGWINCH шеллу companion — максимум перерисовка промпта; всем TUI —
  штатная перерисовка.
- Деплой: протокол не менялся, но демон-код менялся → smoke начинать с
  `pkill -f coveyd; rm -f ~/.covey/coveyd.sock` (квирк stale daemon).

## 4. Non-goals

- Скролл колесом в **чате** живого claude — поведение claude (wheel
  забинден только в Scroll-контексте; `ctrl+o` уже скроллится колесом
  через covey). Отдельная опция на будущее:
  `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1` при спавне (inline-режим,
  нативный scrollback) — не в этом слайсе.
- Cap объёма backfill при attach.
- Дырка/дубли между чтением backfill и подпиской fanout (если есть) —
  существующее поведение, не трогаем.

## 5. Тесты (TDD: скелет → тест → реализация)

- **Unit `ScreenModel.statePreamble`:**
  - feed `?1049h ?1002h ?1006h ?2004h` → преамбула ровно из них
    (плюс допущение 1006 при mouse on);
  - затем feed `?1049l ?1002l` → соответствующие уходят;
  - DECSET, порванный между двумя `feed()`-чанками, парсится (гарантия
    SwiftTerm — тест фиксирует);
  - чистая модель → пустой массив;
  - `applicationCursor` (`?1h`) попадает в преамбулу.
- **Unit `PTYProcess.kick`:** спавн шелла с `trap 'echo WINCHED'
  WINCH` → после `kick()` маркер в выводе.
- **Интеграция IPC:** attach к сессии, чей поток включил alt+mouse →
  первый `.output` начинается с преамбулы, seq не изменён
  (`bf.fromSeq`).
- **Smoke:** `pkill coveyd`, GUI + claude-сессия, рестарт GUI →
  agent-зона: не каша, `ctrl+o` скроллится колесом; companion vim
  перерисован после re-select.
