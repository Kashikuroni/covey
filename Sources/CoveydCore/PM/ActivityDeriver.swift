import Foundation
import CoveyKit

/// Производная активность задачи (spec §7.2, поправка A2): active, если хоть
/// одна привязанная сессия running ИЛИ её последний запуск свежее порога;
/// paused, если привязки есть, но все в простое дольше порога; idle — открытых
/// привязок нет. Чистая логика без таймеров: PMService кормит её переходами
/// StatusMonitor и вызывает при изменениях.
public final class ActivityDeriver {
    public struct SessionState {
        var status: Status
        var lastRunningAt: Int64
    }

    private var sessions: [String: SessionState] = [:]

    public init() {}

    public func onStatus(name: String, status: Status, now: Int64) {
        let prev = sessions[name]
        var s = prev ?? SessionState(status: status, lastRunningAt: now)
        // Активность «до последнего момента»: и пока running, и в момент ухода
        // из running (переход running→idle в t значит: работал до t).
        if status == .running || prev?.status == .running { s.lastRunningAt = now }
        s.status = status
        sessions[name] = s
    }

    public func onSessionRemoved(name: String) {
        sessions[name] = nil
    }

    /// После рестарта демона: засеять известные сессии, чтобы не считать их
    /// активными ложно (lastRunningAt = момент снапшота).
    public func snapshot(names: [String], statuses: [String: Status], now: Int64) {
        for name in names {
            sessions[name] = SessionState(status: statuses[name] ?? .idle,
                                          lastRunningAt: now)
        }
    }

    public func activity(openBindings: [PMBinding],
                         idleThresholdOf: (String) -> Int?,
                         defaultIdleS: Int = PMIdleThreshold.defaultSeconds,
                         now: Int64) -> PMActivity {
        guard !openBindings.isEmpty else { return .idle }
        // Порог задачи — минимальный среди открытых привязок (самая
        // «нетерпеливая» из них задаёт границу активности).
        let threshold = openBindings
            .compactMap { Int64(idleThresholdOf($0.taskID) ?? defaultIdleS) }
            .min() ?? Int64(defaultIdleS)
        for b in openBindings {
            guard let s = sessions[b.coveySession] else { continue } // неизвестная — не активна
            if s.status == .running { return .active }
            if now - s.lastRunningAt < threshold { return .active }
        }
        // Привязки есть, но contributors нет (сессии мертвы/неизвестны демону)
        // или все в простое дольше порога — по семантике D3 это paused,
        // пока PMService не закроет интервал мёртвой сессии.
        return .paused
    }
}
