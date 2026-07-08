# Слайс 28 — браузер issues: список, детали, edit, close, delete (Design Spec)

> Таб Issue инспектора получает браузер GitHub issues проекта: список с
> фаззи-поиском и per-root кешем, детали, редактор (title/body/labels),
> close с причиной, delete с подтверждением — и главный сценарий:
> сессия из issue с именем `#N: заголовок` через NewSessionSheet.
> Композер из слайсов 24–26 не меняется. GUI-only, всё через gh CLI.

## 0. Назначение

Основной сценарий: посмотреть открытые issues проекта и создать сессию
под конкретный issue — чтобы у сессии была конкретная цель. Менеджмент
(edit/close/delete) — вторичный, но полноценный.

## 1. Данные и IssueService

Модели (`Codable + Equatable`, рядом с IssueService):

- `GhIssue`: `number, title, body, state, author, labels, updatedAt, url`;
  `author` — строка-login (в JSON gh это объект `{login, …}` — декодер
  разворачивает), `labels: [GhLabel]`.
- `GhLabel`: `name, color`.

Один gh-вызов тянет список **вместе с телами** — деталям не нужен
второй запрос:

```
gh issue list --json number,title,state,body,author,labels,updatedAt,url \
  --state <open|closed|all> --limit 100
```

`IssueService` (/covey/Sources/covey/IssueService.swift) расширяется
чистыми функциями по образцу `issueCreateArgs` — тестируются без сети:

- `issueListArgs(state:limit:)`
- `issueEditArgs(number:title:body:addLabels:removeLabels:)` — флаги
  только для изменившегося;
- `issueCloseArgs(number:reason:)` — reason: `completed` / `not planned`;
- `issueReopenArgs(number:)`
- `issueDeleteArgs(number:)` — всегда с `--yes`;
- `labelListArgs()` → `gh label list --json name,color`;
- декодеры `parseIssues(Data) -> [GhIssue]?`, `parseLabels(Data) -> [GhLabel]?`.

Процессный код из `IssueService.create` выносится в общий раннер
`runGh(args:dir:) async -> (status: Int32, stdout: Data, stderr: Data)`;
`create` пересаживается на него без изменения поведения (включая
notFound-сообщение при коде 127 и парс URL из stdout).

## 2. IssueBrowserModel и кеш

`IssueBrowserModel` — `@Observable`, один экземпляр в `AppModel`:

- `issues: [GhIssue]` — текущий показанный список;
- `stage: .loading / .ready / .failed(String)` — полноэкранные
  состояния (failed — только когда кеша нет);
- `mode: .list / .detail(number) / .edit(number)`; композер — отдельное
  состояние таба, не режим браузера;
- `stateFilter: .open / .closed / .all` (default `.open`);
- `query: String` — фаззи-фильтр по заголовкам (Fuzzy.swift);
- выделение хранится **номером issue**, не индексом — переживает
  подмену списка;
- `labels: [GhLabel]?` — лениво при первом входе в edit.

### Кеш: stale-while-revalidate

В памяти (не персистится): `[CacheKey: CacheEntry]`, ключ —
`root + stateFilter`, запись — `issues + fetchedAt`. TTL = 120 с.

- Открытие списка / переключение сессии: кеш моложе TTL → показать,
  сети нет. Старше → показать сразу (без «loading»-мигания) + фоновый
  refetch с мини-спиннером «refreshing…» в шапке; ответ подменяет список.
- Фоновый refetch упал → кеш остаётся, строка
  «updated N min ago — refresh failed». Полноэкранный failed-card —
  только без кеша.
- Мутации (edit/close/reopen/delete, а также create из композера) →
  принудительный refetch root. `r` — всегда принудительный.
- Смена root: браузер переключается на кеш нового root (или fetch).

Решение «показать/показать-и-обновить/грузить» — чистая функция от
`(fetchedAt, ttl, now)`.

## 3. Роутинг таба, чорды

- Таб Issue: три экрана — список (дом), детали/редактор, композер.
- `space g l` — открыть инспектор → таб Issue → **список** (новый
  `KeyAction`, буква `l` в git-меню свободна). `space g i` — как
  раньше, сразу композер. Гарды у обоих прежние: «no session»,
  «not a git repo».
- Из списка `n` — композер; esc из композера — назад в список.

## 4. Список

Строка: точка состояния (open — `tk.ok`, closed — `tk.t4`) +
`#12 заголовок`, lineLimit 1; выделение — `accent.opacity(0.2)` (идиома
suggestionList). Над списком: `in: ~/…` (как в композере) + индикатор
фильтра (`open`) + спиннер/возраст кеша при ревалидации. Пустой
список — «no open issues».

Клавиши (фокус в инспекторе, не в поле поиска):

| клавиша | действие |
|---|---|
| `j`/`k`, `↓`/`↑` | выделение |
| `enter` | детали |
| `/` | фокус в поле поиска; esc в поле — очистить, фокус в список |
| `o` | цикл open → closed → all (fetch/кеш per-фильтр) |
| `r` | принудительный refresh |
| `n` | новый issue (композер) |
| `s` | сессия из issue |
| `e` | редактировать |
| `c` | close (открытый) / reopen (закрытый) |
| `x` | delete с подтверждением |
| `b` | открыть в браузере (url из данных) |

Футер шторки: kbd-бейджи ключевых (`enter view · n new · s session ·
/ search`), полный набор — в HelpOverlay.

## 5. Детали и редактор

**Детали** (`enter` из списка): скролл — шапка (`#12`, заголовок,
state-бейдж, автор, дата, лейблы чипами) + тело с `textSelection`.
Действия `s`/`e`/`c`/`x`/`b` работают. `esc` — в список.

**Редактор** (`e`): Title (AyuField) + body (VimEditor, как композер) +
чеклист лейблов (грузится `gh label list` при входе, спиннер;
j/k + space — тогл, идиома toggleRow из NewSessionSheet). Save —
кнопка + enter в Title (контейнерный ⇧enter отброшен: VimEditor
глотает Return, прецедент композера); esc — отмена, назад в детали. Save шлёт только
diff: `--title`/`--body` при изменении, `--add-label`/`--remove-label`
из сравнения «было/стало». Успех → refetch → детали.

## 6. Действия

**Сессия из issue (`s`).** Prefill-канал NewSessionSheet расширяется:
к `newSessionPrefillDir` (= root) добавляется `newSessionPrefillName =
"#12: заголовок"` — обрезка до 60 символов, санитизация под
`validateCreate`. Дальше обычный шит: бранч, worktree, агент.

**Close/reopen (`c`).** Открытый issue → инлайн-промпт в панели (не
window-sheet): `close #12: [c] completed · [n] not planned · [esc]
cancel` → `gh issue close --reason` → тост + refetch. Закрытый →
мгновенный reopen + тост.

**Delete (`x`).** Инлайн-карточка с рамкой `tk.err`: `delete issue
#12? enter delete · esc cancel` → `gh issue delete --yes`. Ошибка прав
(delete — только админам репо) показывается как обычный fail. Успех:
тост, refetch; удалили из деталей — возврат в список.

## 7. Ошибки

- Одна gh-операция в полёте; на время — спиннер, действия заглушены.
- Ошибки действий — компактная строка в панели поверх живого списка
  (statusCard-идиома); полноэкранный failed — только без данных.
- gh не установлен — notFound-сообщение как у create.

## 8. Тесты (TDD: скелет → тест → реализация)

- args-билдеры list/edit/close/reopen/delete/labelList; edit-diff
  (наборы `--add-label`/`--remove-label` из «было/стало»);
- `parseIssues`/`parseLabels` на фикстурах: пустой список, юникод,
  отсутствующие поля;
- формат/санитизация/обрезка имени сессии из issue;
- кеш-политика: `(fetchedAt, ttl, now)` → решение; инвалидация после
  мутаций;
- сохранение выделения по номеру при подмене списка;
- async-клей и UI — тонкие, проверка руками через запуск приложения.

## 9. Вне скоупа

- Комментарии issue (просмотр/написание) — позже, если зачешется.
- Фильтр по лейблам, assignee, milestone.
- Автополлинг/уведомления о новых issues.
- Персист кеша на диск.
- Изменение композера (слайсы 24–26) — не трогаем.
