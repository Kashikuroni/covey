# Covey Roadmap

> Цель: превратить Covey из терминального мультиплексора для агентов в **локальный control plane для агентной разработки** — оркестрация внешних CLI-агентов (Claude Code, Codex, Gemini CLI и др.) плюс собственный native agent, работающий с любой LLM (API, open source, local).

---

## Правила игры

Эти принципы важнее любого пункта ниже. К ним возвращаемся каждый раз, когда хочется «быстро добавить фичу».

1. **Вертикальные срезы.** Каждый этап заканчивается работающим сценарием от UI до daemon, а не набором протоколов «на будущее».
2. **Детерминизм раньше LLM.** `ScriptedProvider` и тесты цикла — до подключения реального API. Базовые функции работают офлайн.
3. **Никакого публичного plugin API**, пока нет трёх зрелых внутренних адаптеров.
4. **Порядок этапов не меняется.** Если сроки поджимают — режем объём внутри этапа, а не переставляем этапы: зависимости между ними реальные.

### Стоп-лист (что мы НЕ делаем)

- ❌ Не превращаем Covey в IDE (редактор, LSP, debugger) — интегрируемся с Zed/VS Code/Xcode/Neovim.
- ❌ Не добавляем 20 агентов простыми string-presets без понимания их состояний.
- ❌ Не строим cloud/team layer до безупречного single-user local опыта.
- ❌ Не делаем LLM обязательным для внутренних функций (summary, классификация — опциональный слой).
- ❌ Не строим визуальный DAG-редактор оркестрации — сначала recipes и task state machine.

---

## Этап 0 — Фундамент и распространяемость

**Срок:** 2–3 недели
**Цель:** продукт можно установить и оценить; архитектура готова к обоим направлениям (внешние адаптеры и native agent).

### Инфраструктура

- [ ] README: demo GIF/video, установка, архитектура, supported agents
- [ ] Description и topics репозитория
- [ ] CI (GitHub Actions): `swift test` + Xcode build, debug и release конфигурации
- [ ] Formatting/lint в CI
- [ ] Первый tagged release + changelog
- [ ] Проверить возможность снизить deployment target (сейчас macOS 26)
- [ ] `SECURITY.md` (минимальная threat model)

### Архитектурный фундамент

- [ ] **IPC handshake + версия протокола** (`hello`/`welcome`, capabilities) — до появления новых agent events
- [ ] UUID как внутренняя identity сессии; `name` — только display name (rename без каскадного перемещения состояния)
- [ ] **Рефакторинг `SessionRegistry`: протокол `SessionRuntime` + `PTYSessionRuntime`** как единственная реализация — ключевое изменение этапа
- [ ] Начать замену stringly-typed API на типы (`SessionID`, `AgentID`, `ProjectID`, enums)

### UX-победы

- [ ] Diagnostics screen: daemon найден, агенты установлены, git/gh доступны, credentials, права socket, рабочая директория
- [ ] IDE handoff (issue #1): открыть worktree в Zed/VS Code/Cursor, command templates вида `["zed", "{worktree}", "{file}:{line}"]`

### Критерий выхода

> Новый пользователь ставит Covey по README и всё работает. CI зелёный. Рефакторинг runtime не сломал существующие тесты.

---

## Этап 1 — Agent-awareness внешних CLI

**Срок:** 4–6 недель
**Цель:** Covey понимает, что делают агенты, а не только рисует их терминалы.

### ExternalAgentAdapter

- [ ] Протокол `ExternalAgentAdapter`: launch spec, resume spec, парсинг output → структурированные события
- [ ] `AgentEvent`: started, thinking, toolStarted/Finished, permissionRequested, questionAsked, testsFinished, contextWarning, completed, failed
- [ ] Адаптер **Claude Code** (приоритет источников: hooks/machine-readable output → session-файлы → terminal parser → эвристика экрана как fallback)
- [ ] Адаптер **Codex**
- [ ] `GenericPTYAdapter` как fallback (текущее поведение)
- [ ] Нормальная status model вместо `running/waiting/idle`: причина ожидания, ожидаемое решение
- [ ] Корректный resume для разных агентов через адаптеры

### Attention Inbox v1

- [ ] Единый список «где нужно моё решение»: причина, время ожидания, сортировка по срочности
- [ ] Уровни `info / action / warning / dangerous`
- [ ] macOS notifications + cooldown и дедупликация
- [ ] Быстрый ответ / permission decision без открытия терминала
- [ ] Переход к нужной строке или prompt в сессии

### Usage

- [ ] Provider-agnostic модель `AgentUsage` вместо прямого чтения Claude credentials
- [ ] Честные метки в UI: `Exact / Estimated / Unknown`

### Параллельно (по кусочку под каждую фичу, не отдельным «месяцем рефакторинга»)

- [ ] Декомпозиция `AppModel`: начать с `AttentionStore` и `SessionStore`
- [ ] `AppCommand` enum для пользовательских действий

### Критерий выхода

> 5 параллельных агентов — и за день ни разу не открываешь терминал «просто проверить»: Inbox сообщает всё сам.

---

## Этап 2 — Native Agent: read-only срез

**Срок:** 4–6 недель
**Цель:** собственный агент существует и изучает код, ничего не меняя. Работает с любой OpenAI-compatible LLM.

### Контракты

- [ ] `LLMProvider` протокол с **каноническими типами Covey** (`ModelRequest`, `ConversationItem`, `ContentBlock`, `ModelEvent`) — не типы OpenAI как внутренняя модель
- [ ] `AgentDefinition` (prompt, tools, policies) отдельно от `ModelSelection` (provider, model, effort)
- [ ] `ModelCapabilities` + валидация при запуске (tool calling required)
- [ ] `CompatibilityProfile` для различий «OpenAI-compatible» серверов

### Runtime

- [ ] `NativeAgentSessionRuntime` внутри `coveyd` (третий daemon не создаём)
- [ ] `AgentRuntime` цикл: request → stream events → tool calls → results → next turn
- [ ] `ScriptedProvider` для детерминированных тестов
- [ ] Один OpenAI-compatible provider (покрывает локальные серверы: llama.cpp, Ollama, LM Studio и облачные совместимые API)
- [ ] Credentials только через Keychain (`credential: keychain:...` в конфиге)
- [ ] Cancellation (во время streaming и во время tool execution)

### Tools (только read-only)

- [ ] `list_directory`, `read_file`, `search_text`
- [ ] `git_status`, `git_diff`
- [ ] `ask_user`

### UI

- [ ] Activity view (структурированные события, **не** fake terminal)
- [ ] Вкладки: Activity / Conversation; raw request/response — в Developer Mode
- [ ] IPC: `createAgentRun`, `sendAgentMessage`, `cancelAgentRun`, subscribe + agent events

### Порядок внедрения

1. Сначала полный сценарий на `ScriptedProvider` (create session → tool calls → ответ) без реальной LLM.
2. Только потом — реальный OpenAI-compatible endpoint.

### Критерий выхода

> «Объясни, как устроена авторизация в этом проекте» работает на локальном Qwen и на облачном API с одним и тем же Agent Definition.

---

## Этап 3 — Native Agent пишет код безопасно

**Срок:** 4–6 недель
**Цель:** агент реализует небольшие изменения; каждый side effect контролируется.

### Безопасная запись

- [ ] `WorkspaceHandle` sandbox: защита от `../` traversal, абсолютных путей, symlink escape, запрещённых glob
- [ ] `apply_patch` с `expectedSHA256`: conflict вместо перезаписи, если файл изменился после чтения
- [ ] Worktree per run по умолчанию
- [ ] `run_command` только в **captured mode** (structured stdout/stderr/exit code, timeout); interactive PTY mode — позже

### Permission Broker

- [ ] `ToolRisk` классификация: readOnly / workspaceWrite / commandExecution / networkAccess / dependencyChange / destructiveGit / outsideWorkspace
- [ ] Decisions: allow / allowOnce / allowForRun / askUser / deny
- [ ] Policy в конфиге (allow/deny списки команд, paths)
- [ ] Permission requests → **Attention Inbox из этапа 1** (не блокируют daemon)

### Завершение и восстановление

- [ ] `complete_task` tool + `CompletionPolicy` (нельзя завершиться без верификации: требовать git diff, verification command)
- [ ] **SQLite event store для agent runs** (append-only: agent_events, tool_invocations, permission_decisions, usage) — начать с native agent, PTY-историю не мигрировать сразу
- [ ] Восстановление run после перезапуска daemon (replay из событий)

### Обязательные тесты

- [ ] Agent loop: tool call → result → next turn; malformed arguments; unknown tool; max turns; cancellation; provider retry/auth failure
- [ ] Workspace security: traversal, absolute path, symlink escape, stale write, denied glob, forbidden executable
- [ ] Recovery: coveyd restarted → run restored; unfinished command marked interrupted

### Критерий выхода

> Агент реализует небольшой баг-фикс с тестами. Каждый side effect прошёл permission check. Run переживает перезапуск daemon.

---

## Этап 4 — Управление результатом

**Срок:** 4–6 недель
**Цель:** разработчик управляет качеством результата, а не наблюдает за терминалами.

### Task model

- [ ] `AgentTask` поверх сессий: title, acceptance criteria, sessions, worktrees, artifacts, policy, budget
- [ ] State machine: Draft → Ready → Running → WaitingForHuman → Reviewing → ChangesRequested → ReadyToMerge → Completed (+ Failed/Blocked/Abandoned)

### Outcome View (первая версия — без LLM)

- [ ] Summary / Changes / Verification / Risks / Timeline
- [ ] Источники: git diff, process events, exit codes, test parsers, command history, file classification
- [ ] LLM-summary — позже, как опциональный слой, не источник истины

### Двусторонний diff review

- [ ] Комментарий к строкам diff → структурированный feedback агенту
- [ ] Действия: Comment / Request change / Accept file / Reject hunk / Send all feedback / Run tests / Prepare merge

### Policies и quality gates

- [ ] `.covey/project.yml`: agents, execution (network, destructive commands, allowed/denied paths), quality (required commands, max changed files), merge strategy
- [ ] Три класса операций: автоматически / спросить / запрещено политикой

### Критерий выхода

> Цикл «задача → работа агента → Outcome View → замечания в diff → агент исправляет → gates → merge» проходит без открытия терминала.

---

## Этап 5 — Мультипровайдерность и оркестрация

**Срок:** ongoing
**Цель:** один Agent Definition работает с несколькими API; несколько исполнителей на одну задачу.

### Providers

- [ ] Anthropic Messages provider
- [ ] Gemini provider
- [ ] OpenAI Responses provider
- [ ] Contract tests: один сценарий (read README → tool call → result → final answer) через каждый adapter
- [ ] Model switching в середине run (canonical history — источник истины, provider session ID — только оптимизация)

### Долгие задачи

- [ ] Compaction (отдельная policy: threshold, preserve recent turns, что сохранять в summary)
- [ ] Async commands (start / read output / wait / stop)
- [ ] Budgets: на задачу, на проект; предупреждение перед дорогим запуском; остановка runaway session
- [ ] Backpressure terminal output: batching, лимит pending bytes, dropped-range events

### Recipes (не граф-редактор)

- [ ] Implement and review (implementation agent → tests → independent reviewer → human review → merge)
- [ ] Parallel investigation (несколько агентов → synthesis)
- [ ] Alternative implementations (сравнение diffs и verification)
- [ ] Reviewer agents, планировщик ролей (planner → дорогая модель, executor → дешёвая)

### Позже

- [ ] Signing/notarization `.dmg`, автообновление (Sparkle), crash logs / diagnostic bundle
- [ ] Skills, MCP, hooks, subagents
- [ ] Remote `coveyd` через SSH, container/VM runners
- [ ] Team layer — только после безупречного локального опыта

---

## Итоговая архитектурная картина

```text
                    Covey Task
                        │
                 Session Runtime
                 ┌──────┴──────┐
                 │             │
           External CLI     Native Agent
                 │             │
        ExternalAgentAdapter   AgentRuntime
                               ├── LLMProvider
                               ├── ToolRegistry
                               ├── ContextManager
                               ├── PermissionBroker
                               └── EventStore
```

- `LLMProvider` — как поговорить с моделью
- `AgentDefinition` — как агент должен себя вести
- `AgentRuntime` — как выполнять цикл работы
- `Tool` — что агент может сделать
- `Workspace` — где он может это сделать
- `PermissionBroker` — разрешено ли это делать

## Три функции, которые меняют всё

1. **Agent Adapter + structured events** — без этого Covey остаётся терминальным менеджером.
2. **Attention Inbox** — человеческое внимание становится дефицитным ресурсом при работе с многими агентами.
3. **Outcome/Diff Review с обратной связью агенту** — управление качеством, а не наблюдение за процессами.
