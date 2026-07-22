import Foundation

/// A system-notification payload for a usage window that crossed the
/// alert threshold.
struct LimitAlert: Equatable {
    let windowKey: String    // "5h" | "7d"
    let title: String        // "Claude 5h limit at 82%"
    let body: String         // "18% left · resets in 2h13m"
}

/// Same boundary as `usageLevel`'s .err tier.
let limitAlertThreshold = 80.0

/// Pure limit-crossing detector, per agent. `notified` maps a prefixed key
/// ("<agent>:<windowKey>") to the resetUnix of the cycle already alerted (0
/// when resets_at was absent). Only this agent's keys are touched; other
/// agents' markers in the shared map are preserved. Returns alerts to post
/// plus the updated marker map.
func limitAlerts(agent: String,
                 windows: [(key: String, window: UsageWindow?)],
                 notified: [String: Int64], now: Date)
    -> (alerts: [LimitAlert], notified: [String: Int64]) {
    var marks = notified
    var alerts: [LimitAlert] = []
    let prefix = agent.lowercased()
    for (key, window) in windows {
        let markKey = "\(prefix):\(key)"
        guard let w = window else { continue }   // network gap: keep markers
        if w.utilization < limitAlertThreshold {
            marks[markKey] = nil
            continue
        }
        let mark = w.resetUnix ?? 0
        guard marks[markKey] != mark else { continue }
        marks[markKey] = mark
        let pct = Int(w.utilization.rounded())
        var body = "\(max(0, 100 - pct))% left"
        if let reset = w.resetUnix {
            body += " · resets in \(remainingLabel(resetUnix: reset, now: now))"
        }
        alerts.append(LimitAlert(windowKey: key,
                                 title: "\(agent) \(key) limit at \(pct)%",
                                 body: body))
    }
    return (alerts: alerts, notified: marks)
}
