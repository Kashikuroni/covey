import Foundation
import CoveyKit

/// Фасад домена PM: все pm*-операции протокола, идемпотентность по request_id,
/// события-envelope, производная активность, расписание rollup'ов. Вся
/// мутабельность — на serial-очереди `q`.
public final class PMService {
    public var onEvent: ((PMEventEnvelope) -> Void)?

    private let q = DispatchQueue(label: "covey.pm.service")
    private let db: PMDB
    private let projects: ProjectStore
    private let tasks: TaskStore
    private let bindings: BindingService
    private let rollups: RollupService
    private let analytics: AnalyticsQuery
    private let now: () -> Int64
    /// provider sessionId → ключ вёдер TokenAggregator. Claude: uuid
    /// транскрипта из resumeCmd; Codex: nil (роллауты матчятся демоном иначе).
    private let resolveExternal: (Session) -> String?
    /// Имя сессии → Session из реестра (резолв external id при ручной привязке).
    private let sessionByName: (String) -> Session?
    /// Non-nil, если pm.db был восстановлен после порчи — start эмитит событие.
    private let recoveryNote: String?
    private var didAnnounceRecovery = false
    private var deriver = ActivityDeriver()
    private var nextSeq: Int64 = 1
    private var replay: [String: (fingerprint: Int, result: ServerMessage.Result)] = [:]
    private var replayOrder: [String] = []
    private let replayCap = 256
    private var lastActivity: [String: PMActivity] = [:]
    private var rollupDebounce: DispatchSourceTimer?
    private var dailyTimer: DispatchSourceTimer?
    private var activityTimer: DispatchSourceTimer?

    public init(db: PMDB, projects: ProjectStore, tasks: TaskStore,
                bindings: BindingService, rollups: RollupService,
                analytics: AnalyticsQuery,
                resolveExternal: @escaping (Session) -> String? = { _ in nil },
                sessionByName: @escaping (String) -> Session? = { _ in nil },
                recoveryNote: String? = nil,
                now: @escaping () -> Int64) {
        self.db = db; self.projects = projects; self.tasks = tasks
        self.bindings = bindings; self.rollups = rollups
        self.analytics = analytics
        self.resolveExternal = resolveExternal
        self.sessionByName = sessionByName
        self.recoveryNote = recoveryNote
        self.now = now
        nextSeq = ((try? db.query("SELECT MAX(seq) FROM events", []) { $0.int(0) }.first) ?? 0) + 1
    }

    // MARK: - lifecycle демона

    /// Вызывается из main.swift после сборки: снапшот активностей, закрытие
    /// интервалов мёртвых сессий, догон rollup'ов.
    public func start(liveSessions: [String], statuses: [String: Status]) {
        q.async { [weak self] in
            guard let self else { return }
            if let note = self.recoveryNote, !self.didAnnounceRecovery {
                self.didAnnounceRecovery = true
                self.emit("pm.recovered", "pm", nil, value: note)
            }
            self.deriver.snapshot(names: liveSessions, statuses: statuses, now: self.now())
            try? self.bindings.closeOpen(notIn: Set(liveSessions), now: self.now())
            self.scheduleRollup(delay: 0)
            self.refreshActivities()
        }
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + 6 * 3600, repeating: 6 * 3600)
        timer.setEventHandler { [weak self] in self?.scheduleRollup(delay: 0) }
        timer.resume()
        dailyTimer = timer
        // Review finding 8: активность — стеночное условие (простой > N), а
        // StatusMonitor стреляет только на переходы. Тик раз в 30с пересчитывает
        // active→paused без новых событий.
        let activityTimer = DispatchSource.makeTimerSource(queue: q)
        activityTimer.schedule(deadline: .now() + 30, repeating: 30)
        activityTimer.setEventHandler { [weak self] in self?.tickActivities() }
        activityTimer.resume()
        self.activityTimer = activityTimer
    }

    /// Пере-вывод активностей по текущим часам (таймер 30с; тесты — напрямую).
    public func tickActivities() {
        q.async { [weak self] in self?.refreshActivities() }
    }

    public func sessionAdded(_ session: Session) {
        q.async { [weak self] in
            guard let self else { return }
            // Фиксируем external_session_id открытых привязок этой сессии
            // (spec §7.3): ключ вёдер TokenAggregator для атрибуции rollup'ов.
            if let key = self.resolveExternal(session) {
                for b in (try? self.bindings.openBindings()) ?? []
                where b.coveySession == session.name && b.externalSessionID == nil {
                    try? self.bindings.setExternalSessionID(bindingID: b.id, key: key)
                }
            }
            self.refreshActivities()
        }
    }

    public func sessionGone(name: String) {
        q.async { [weak self] in
            guard let self else { return }
            self.deriver.onSessionRemoved(name: name)
            let affected = (try? self.bindings.openBindings())?.filter { $0.coveySession == name } ?? []
            try? self.bindings.closeOpen(forSession: name, now: self.now())
            for b in affected { self.emit("session.unbound", b.taskID, nil) }
            self.refreshActivities()
            self.scheduleRollup(delay: 5)
        }
    }

    public func onStatus(name: String, status: Status, now stamp: Int64? = nil) {
        q.async { [weak self] in
            guard let self else { return }
            self.deriver.onStatus(name: name, status: status, now: stamp ?? self.now())
            self.refreshActivities()
        }
    }

    // MARK: - dispatch

    public func handle(_ op: Request.Op) -> ServerMessage.Result {
        q.sync { dispatch(op) }
    }

    /// Finding 4: pm-операции уходят с serial-очереди IPC (spawn/rollup не
    /// должны замораживать весь протокол демона). Reply потокобезопасен —
    /// sink.send уже зовут с createQueue.
    public func handleAsync(_ op: Request.Op,
                            reply: @escaping (ServerMessage.Result) -> Void) {
        q.async { [weak self] in
            guard let self else { return }
            reply(self.dispatch(op))
        }
    }

    private func dispatch(_ op: Request.Op) -> ServerMessage.Result {
        switch op {
        case .pmProjectsList:
            return (try? projects.list(includeArchived: true)).map { .pmProjects($0) }
                ?? .error(code: "pmDbError", message: "projects.list failed")

        case .pmProjectsRegister(let root):
            do {
                let p = try projects.register(rootPath: root, name: nil, now: now())
                emit("project.changed", p.id, p.revision)
                return .pmProjects([p])
            } catch { return pmError(error) }

        case .pmProjectsRename(let id, let name, let rev, let rid):
            return idempotent(rid, op) {
                let p = try projects.rename(id: id, to: name, expectedRevision: rev, now: now())
                emit("project.changed", p.id, p.revision)
                return .pmProjects([p])
            }

        case .pmProjectsArchive(let id, let archived, let rev, let rid):
            return idempotent(rid, op) {
                let p = try projects.archive(id: id, archived: archived,
                                             expectedRevision: rev, now: now())
                emit("project.changed", p.id, p.revision)
                return .pmProjects([p])
            }

        case .pmProjectsReorder(let ids, let rid):
            return idempotent(rid, op) {
                try projects.reorder(ids: ids)
                emit("project.changed", "all", nil)
                return .ok
            }

        case .pmTasksCreate(let pid, let title, let body, let assignee, let threshold, let rid):
            return idempotent(rid, op) {
                let t = try tasks.create(projectID: pid, title: title, body: body ?? "",
                                         assignee: assignee, idleThresholdS: threshold, now: now())
                emit("task.updated", t.id, t.revision)
                return .pmTask(t)
            }

        case .pmTasksUpdate(let id, let title, let body, let threshold, let rev, let rid):
            return idempotent(rid, op) {
                let t = try tasks.update(id: id, title: title, body: body,
                                         idleThresholdS: threshold,
                                         expectedRevision: rev, now: now())
                emit("task.updated", t.id, t.revision)
                return .pmTask(t)
            }

        case .pmTasksSetStatus(let id, let lifecycle, let rev, let rid):
            return idempotent(rid, op) {
                guard var to = PMTaskLifecycle(rawValue: lifecycle) else {
                    throw PMStoreError.badRequest("unknown lifecycle")
                }
                // Spec §7.1: reopen из терминального → in_progress при живых
                // привязках, иначе ready (finding 10).
                if to == .inProgress, let current = try tasks.byID(id),
                   [.done, .failed, .cancelled].contains(current.lifecycle),
                   ((try? bindings.openBindings(taskID: id)) ?? []).isEmpty {
                    to = .ready
                }
                let t = try tasks.setStatus(id: id, to: to, expectedRevision: rev, now: now())
                emit("task.lifecycle_changed", t.id, t.revision)
                return .pmTask(t)
            }

        case .pmTasksList(let pid):
            let list = (try? tasks.list(projectID: pid)) ?? []
            return .pmTasks(list.map(taskView))

        case .pmTasksBind(let taskID, let session, let rid):
            return idempotent(rid, op) {
                let b = try bindings.bind(taskID: taskID, session: session, now: now())
                // Finding 3: привязка живой сессии фиксирует external_session_id
                // сразу — sessionAdded этой сессии стрелял до привязки.
                if let key = resolveExternalFor(sessionName: session) {
                    try? bindings.setExternalSessionID(bindingID: b.id, key: key)
                }
                emit("session.bound", b.taskID, nil)
                refreshActivities()
                scheduleRollup(delay: 5)
                return .pmBinding(b)
            }

        case .pmTasksUnbind(let bindingID, let rid):
            return idempotent(rid, op) {
                try bindings.unbind(bindingID: bindingID, now: now())
                emit("session.unbound", bindingID, nil)
                refreshActivities()
                scheduleRollup(delay: 5)
                return .ok
            }

        case .pmTasksSpawn(let taskID, let rid):
            return idempotent(rid, op) {
                let session = try bindings.spawn(taskID: taskID, now: now())
                guard let open = try bindings.openBindings(taskID: taskID).last else {
                    throw PMStoreError.badRequest("spawn produced no binding")
                }
                emit("session.bound", taskID, nil)
                refreshActivities()
                return .pmSpawned(open, session)
            }

        case .pmAnalyticsQuery(let pid, let taskID, let rangeDays):
            let range = rangeDays ?? 30
            if let taskID {
                let tl = (try? analytics.taskTimeline(taskID: taskID, rangeDays: range, now: now())) ?? []
                return .pmAnalytics(PMAnalyticsResult(project: nil, taskTimeline: tl))
            }
            let summary = (try? analytics.projectSummary(projectID: pid, rangeDays: range, now: now()))
                ?? PMProjectAnalytics(projectID: pid, taskCounts: [:], totals: PMTokenTotals(),
                                      costUSD: nil, allModelsPriced: true, byModel: [],
                                      tasksDone: 0, tasksFailed: 0)
            return .pmAnalytics(PMAnalyticsResult(project: summary, taskTimeline: []))

        default:
            return .error(code: "pmBadRequest", message: "not a pm op")
        }
    }

    // MARK: - helpers (на очереди q)

    /// Ключ вёдер для сессии по имени (реестр демона + резолвер провайдера).
    private func resolveExternalFor(sessionName: String) -> String? {
        guard let session = sessionByName(sessionName) else { return nil }
        return resolveExternal(session)
    }

    private func taskView(_ t: PMTask) -> PMTaskView {
        let open = (try? bindings.openBindings(taskID: t.id)) ?? []
        let a = deriver.activity(openBindings: open,
                                  idleThresholdOf: { _ in t.idleThresholdSeconds },
                                  now: now())
        return PMTaskView(task: t, activity: a, openBindings: open)
    }

    private func refreshActivities() {
        guard let all = try? tasks.list(projectID: nil, includeArchived: false) else { return }
        for t in all {
            let v = taskView(t)
            if lastActivity[t.id] != v.activity {
                lastActivity[t.id] = v.activity
                emit("task.activity_changed", t.id, t.revision, value: v.activity.rawValue)
            }
        }
    }

    private func scheduleRollup(delay: TimeInterval) {
        rollupDebounce?.cancel()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + delay)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.rollupDebounce = nil
            try? self.rollups.recompute(nowMs: self.now() * 1000)
        }
        rollupDebounce = t
        t.resume()
    }

    private func emit(_ type: String, _ entityID: String, _ revision: Int64?, value: String? = nil) {
        let env = PMEventEnvelope(eventID: UUID().uuidString, seq: nextSeq,
                                  entityID: entityID, entityRevision: revision,
                                  type: type, value: value, occurredAt: now())
        nextSeq += 1
        try? db.run("""
            INSERT OR REPLACE INTO events (id, seq, type, entity_id, entity_revision, occurred_at)
            VALUES (?,?,?,?,?,?)
            """, [.text(env.eventID), .int(env.seq), .text(env.type),
                  .text(env.entityID), revision.map { .int($0) } ?? .null, .int(env.occurredAt)])
        onEvent?(env)
    }

    private func idempotent(_ requestID: String, _ op: Request.Op,
                            _ body: () throws -> ServerMessage.Result) -> ServerMessage.Result {
        let fingerprint = String(describing: op).hashValue
        if let cached = replay[requestID] {
            guard cached.fingerprint == fingerprint else {
                return .error(code: "pmRequestIdReused", message: "request id used with different payload")
            }
            return cached.result
        }
        do {
            let result = try body()
            replay[requestID] = (fingerprint, result)
            replayOrder.append(requestID)
            if replayOrder.count > replayCap { replay[replayOrder.removeFirst()] = nil }
            return result
        } catch {
            return pmError(error)
        }
    }

    private func pmError(_ error: Error) -> ServerMessage.Result {
        switch error as? PMStoreError {
        case .stale: return .error(code: "pmStale", message: "revision mismatch — reload and retry")
        case .notFound(let id): return .error(code: "pmNotFound", message: "no entity: \(id)")
        case .duplicate(let id): return .error(code: "pmDuplicate", message: "duplicate: \(id)")
        case .badRequest(let m): return .error(code: "pmBadRequest", message: m)
        default: return .error(code: "pmDbError", message: "\(error)")
        }
    }
}
