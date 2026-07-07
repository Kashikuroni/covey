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

/// Pure limit-crossing detector. `notified` maps a window key to the
/// resetUnix of the window cycle already alerted (0 when resets_at was
/// absent). Returns alerts to post plus the updated marker map.
func limitAlerts(usage: Usage, notified: [String: Int64], now: Date)
    -> (alerts: [LimitAlert], notified: [String: Int64]) {
    var marks = notified
    var alerts: [LimitAlert] = []
    // Sonnet's 7d window is deliberately absent: chip-only, no alerts.
    for (key, window) in [("5h", usage.fiveHour), ("7d", usage.sevenDay)] {
        guard let w = window else { continue }   // network gap: keep markers
        if w.utilization < limitAlertThreshold {
            marks[key] = nil
            continue
        }
        let mark = w.resetUnix ?? 0
        guard marks[key] != mark else { continue }
        marks[key] = mark
        let pct = Int(w.utilization.rounded())
        var body = "\(max(0, 100 - pct))% left"
        if let reset = w.resetUnix {
            body += " · resets in \(remainingLabel(resetUnix: reset, now: now))"
        }
        alerts.append(LimitAlert(windowKey: key,
                                 title: "Claude \(key) limit at \(pct)%",
                                 body: body))
    }
    return (alerts: alerts, notified: marks)
}
