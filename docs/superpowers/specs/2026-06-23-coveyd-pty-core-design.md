# Slice 1 — CoveyKit-модели + PTY-ядро coveyd (Design Spec)

> Дата: 2026-06-23
> Источник верхнеуровневого брифа: `HANDOFF.md` (§3, §4, §11).
> Это спека **первого среза** многослойного порта `covey`. Здесь — только
> изолированное PTY-ядро демона без IPC и без UI.

## 0. Контекст и метод работы

- Greenfield-порт Rust-приложения `agents_multiplexer` на нативный macOS/Swift.
  Tmux выкинут; lifecycle PTY/сессий владеет Swift-демон `coveyd` (см. `HANDOFF.md` §2, §4).
- Строим **снизу вверх**: первый срез — самый новый и рискованный кусок (§4),
  проверяемый изолированно.
- Метод: **TDD** (тест → реализация до зелёного). Вся проверка среза — через `swift test`;
  живую ручную проверку откладываем до появления UI.
- Рабочий цикл: реализацию пишет пользователь руками по шагам; ассистент даёт план,
  объясняет и выступает ревьювером. Все git-операции записи — за пользователем.

## 1. Границы среза

### В scope
- SwiftPM-пакет `covey` с таргетами:
  - `CoveyKit` — library (только Codable-модели на этом срезе).
  - `coveyd` — executable (PTY-ядро; точка входа `main.swift` — пока минимальная заглушка,
    реальный запуск появится в срезе 2 с IPC-сервером).
  - `CoveyKitTests`, `coveydTests`.
- `CoveyKit/Models.swift`: `Session`, `GitInfo`, `Status` (Codable). `State`, `Usage`,
  `SessionVM` — **отложены** до своих слоёв.
- `coveyd/ScrollbackBuffer.swift` — ограниченный ring-буфер с монотонным `seq` и backfill.
- `coveyd/PTYProcess.swift` — один `forkpty`-ребёнок в одном PTY.
- `coveyd/SessionRegistry.swift` — in-memory реестр PTY по имени.

### Отложено (следующие срезы)
- IPC-сервер (Unix-сокет `~/.covey/coveyd.sock`, NDJSON, attach/input/resize/события) — срез 2.
- **Status inference** (§4: порт `parse_prompt` / `content_hash` из `amux-core/src/status.rs`)
  — срез 2/3. Это IPC-событие `statusChanged` и требует Rust-первоисточника; чистый
  PTY-пул проверяется без него.
- Персистентность реестра / `state.toml`, usage-лимиты, вся UI — позже.

### Решение по размещению
- **Модели → `CoveyKit`** (переиспользуются клиентом).
- **`ScrollbackBuffer` / `PTYProcess` / `SessionRegistry` → `coveyd`** (клиенту ring-буфер
  не нужен — он получит готовый поток байт по IPC). Граница чище.

## 2. Сборка / структура

- На этом срезе — **чистый SwiftPM** (`Package.swift`), нужны только `CoveyKit` + `coveyd`.
- **Xcode-проект** как хост для будущего GUI-app-таргета добавим, когда дойдём до app-слоя
  (CoveyKit/coveyd останутся локальными SwiftPM-пакетами, на которые сошлётся .xcodeproj).
- Минимальный таргет macOS: **26** (`swift-tools-version: 6.2`, `.macOS(.v26)`) — пет-проект
  под себя на Apple Silicon, хотим новейшие SDK/Kits без `if #available`. (`HANDOFF.md` §11
  предлагал 13+, сознательно подняли пол.)

## 3. Модели (CoveyKit)

Порт из `HANDOFF.md` §3, семантика полей — по Rust-первоисточникам (§10 брифа).

```swift
struct Session: Codable, Equatable {
    var name: String          // уникальный id
    var dir: String           // директория запуска
    var cwd: String           // текущий рабочий каталог (best-effort)
    var agent: String         // метка агента, напр. "claude"
    var created: Int64        // epoch seconds
    var git: GitInfo?         // ветка + added/removed
    var worktreeRepo: String? // корень репозитория, если dir — git worktree
}

struct GitInfo: Codable, Equatable { var branch: String; var added: UInt32; var removed: UInt32 }

enum Status: Codable, Equatable { case running, waiting, idle }  // инференс — позже (срез 2/3)
```

- `created` стампится при создании сессии (epoch seconds). На срезе передаём извне
  (в ядро не тащим запрещённые `Date.now()`-зависимости тестов — стампим в registry).
- Round-trip Codable-тест обязателен.

## 4. Компоненты и интерфейсы

### 4.1 `ScrollbackBuffer`
Назначение: хранить ограниченный объём недавнего вывода PTY с backfill для позднего клиента.

- Хранит сырые байты в ring-буфере с фиксированным лимитом (напр. N МБ — конфиг через init).
- `seq` — **абсолютное байтовое смещение** от старта сессии (общее число записанных байт).
- Интерфейс (ориентир):
  - `append(_ bytes: [UInt8]) -> (from: Int, to: Int)` — диапазон seq добавленного.
  - `since(_ seq: Int) -> (bytes: [UInt8], fromSeq: Int, gapped: Bool)` — всё с `seq` и новее;
    если `seq` уже вытеснен — доступный хвост + `gapped: true`.
  - `headSeq: Int` (самый старый доступный), `tailSeq: Int` (следующий за последним).
- Зависимости: нет. Чистая структура.

### 4.2 `PTYProcess`
Назначение: владеть одним `forkpty`-ребёнком.

- `spawn(argv:env:cwd:cols:rows:) throws` — `forkpty`, в ребёнке `chdir(cwd)` + `execvp(argv)`;
  при провале exec — `_exit(127)`.
- `write(_ bytes: [UInt8])` — в master fd.
- `resize(cols:rows:)` — `ioctl(masterFD, TIOCSWINSZ, &winsize)`.
- `kill()` — идемпотентно: сигнал ребёнку, гасит read-source, закрывает master fd.
- Колбэки: `onOutput(bytes: [UInt8], seq: Int)`, `onExit(code: Int32)`.
- Внутри: вывод пишется в собственный `ScrollbackBuffer`, затем `onOutput`.
- Зависимости: Darwin (`forkpty`, `TIOCSWINSZ`, `waitpid`, `execvp`, `chdir`), `ScrollbackBuffer`.

### 4.3 `SessionRegistry`
Назначение: реестр `name -> (Session, PTYProcess)`.

- `create(dir:agent:argv:name?) -> Session` — уникальное имя (генерит, если не задано),
  стампит `created`, спавнит `PTYProcess`.
- `kill(name:)`, `list() -> [Session]`, `get(name:)`, `attachOutput(name:) -> stream/колбэк`.
- Выход ребёнка (`onExit`) сам чистит запись из реестра.
- Уникальность имён: дубль → ошибка (зафиксировано; не молчаливое переименование).
- Зависимости: `PTYProcess`, модели.

### 4.4 `coveyd/main.swift` — точка входа (заглушка)
- На этом срезе — минимальная заглушка (исполняемый таргет должен собираться, но ничего
  существенного не делает). Реальная точка входа — IPC-сервер — появится в срезе 2.
- Логика ядра (`ScrollbackBuffer` / `PTYProcess` / `SessionRegistry`) живёт в отдельных
  файлах таргета `coveyd` и проверяется через `coveydTests`, без запуска executable.

## 5. Технические решения

### 5.1 forkpty из Swift
`forkpty` объявлен в `<util.h>`, доступен через `import Darwin`. **Шаг-риск №1:** проверить
видимость символа в toolchain до остального. Если не виден — добавить C-таргет-шим `CPTY`
(`#include <util.h>` + module map), линкуемый в `coveyd`.

### 5.2 Поток данных (один процесс)
```
forkpty() ─► child: chdir(cwd); execvp(argv) в slave-PTY (termios, winsize cols×rows)
          └► parent: master fd
read-loop (DispatchSource) ─► buffer.append(bytes) ─► onOutput(bytes, seq)
write(bytes)  ─► write(masterFD, …)
resize(c,r)   ─► ioctl(masterFD, TIOCSWINSZ, &winsize)
child exit    ─► read EOF/EIO ─► waitpid ─► onExit(code) ─► registry чистит
```

### 5.3 Конкурентность
- На каждый PTY — один **`DispatchSource.makeReadSource(fileDescriptor:)`** на serial-очереди
  (без блокирующего потока на сессию; легко гасить при kill).
- Запись и мутации реестра/буфера сериализуем через выделенную `DispatchQueue`
  (позже возможен переход на `actor`), чтобы исключить гонки.

### 5.4 seq и backfill
`seq` = абсолютное байтовое смещение от старта. `append` возвращает диапазон; `since(seq:)`
отдаёт хвост с `seq`; вытесненный seq → доступный хвост + `gapped: true`.

### 5.5 Кодировка
Ядро оперирует **сырыми байтами** (`[UInt8]`/`Data`), без интерпретации UTF-8/VT — это
работа SwiftTerm на более позднем слое. Buffer и потоки байт-прозрачны.

### 5.6 Обработка ошибок (без крашей демона)
- `forkpty` < 0 → `throws PTYError.spawnFailed(errno)`.
- exec в ребёнке упал → `_exit(127)` → родитель видит `onExit(127)`.
- `read` EIO/EOF → нормальное завершение, `waitpid` за кодом (не ошибка).
- `write` EAGAIN/EPIPE → лог, демон не валится (EPIPE = ребёнок умер → обработается через exit).
- `kill` идемпотентен; двойной kill / несуществующее имя → no-op либо `throws` (зафиксировать).

## 6. Тест-план (TDD)

### `ScrollbackBufferTests` (пишем первым, без PTY)
- append увеличивает `tailSeq` на число байт; `since(0)` отдаёт всё.
- `since(seq:)` с середины — только хвост с верным `fromSeq`.
- переполнение лимита: старые байты вытеснены, `headSeq` сдвинут.
- `since(seq:)` с вытесненного seq → хвост + `gapped: true`.
- границы: пустой буфер; `since` за пределами tail → пусто; не падает.

### `PTYProcessTests` (реальные дочерние процессы, ожидание через expectation, без `sleep`)
- spawn `/bin/echo hello` → `onOutput` содержит "hello", затем `onExit(0)`.
- spawn `/bin/cat`: write "ping\n" → эхо "ping"; `kill` → `onExit`.
- exec несуществующего бинарника → `onExit(127)` (или `spawn throws` — зафиксировать).
- resize до spawn в winsize и `resize()` после — проверка через дочерний `stty size`.
- спавн с `cwd` → дочерний `pwd` совпадает.

### `SessionRegistryTests`
- create даёт уникальное имя/Session; list возвращает живые.
- два create → две независимые сессии, вывод не смешивается.
- kill убирает из list и шлёт `onExit`; выход ребёнка сам чистит реестр.
- дубль имени → ошибка.

Живая ручная проверка интерактивного терминала откладывается до появления UI-слоя.

## 7. Definition of Done (срез 1)
1. `swift build` и `swift test` зелёные.
2. Все юнит-наборы из §6 проходят.
3. Нет утечек блокирующих потоков (kill гасит read-source и закрывает fd).
4. Ядро байт-прозрачно; модели `Session`/`GitInfo`/`Status` — Codable + round-trip тест.

## 8. Следующий срез
IPC-сервер (Unix-сокет `~/.covey/coveyd.sock`, NDJSON request/response + события),
оборачивающий `SessionRegistry`: `list/create/kill/rename/attach/detach/input/resize` +
события `output/sessionAdded/sessionRemoved/statusChanged/exited` (`HANDOFF.md` §4).
Туда же — порт status inference.
