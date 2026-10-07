import Foundation

/// A system-notification payload for a usage window that crossed the
/// alert threshold.
struct LimitAlert: Equatable {
    let windowKey: String    // "5h" | "7d"
    let title: String        // "Claude 5h limit at 82%"
    let body: String         // "18% left · resets in 2h13m"
}

/// Прогнозная лестница §7: overflow → ETA<60 → ETA<15 («критично»), плюс
/// отдельный imminent-алерт по config. Один алерт на (окно, ступень, resetAt).
/// Маркер кодируется `resetAt * 10 + level` (уровень 9 — imminent): смена окна
/// (другой resetAt) обнуляет лестницу, повтор на той же ступени молчит.
func predictiveAlerts(forecast: GLMForecast?,
                      config: GLMForecastConfigSection,
                      notified: [String: Int64], now: Date)
    -> (alerts: [LimitAlert], notified: [String: Int64]) {
    var marks = notified
    var alerts: [LimitAlert] = []
    guard let f = forecast else { return (alerts, marks) }
    let hasActive = f.agents.contains(where: \.active)
    func etaMinutes(_ w: GLMWindowForecast) -> Double? {
        w.exhaustionAt.map { (Double($0) / 1000 - now.timeIntervalSince1970) / 60 }
    }
    for (key, w) in [("predict:five", f.fiveHours), ("predict:week", f.weekly)] {
        guard let w, w.verdict == .overflow, hasActive,
              let eta = etaMinutes(w), eta > 0, let resetAt = w.resetAt else { continue }
        let level: Int
        let suffix: String
        if eta < 15 { level = 2; suffix = " (критично)" }
        else if eta < 60 { level = 1; suffix = "" }
        else { level = 0; suffix = "" }
        let markKey = "glm:\(key)"
        let oldMark = marks[markKey] ?? 0
        if oldMark / 10 == resetAt, level <= Int(oldMark % 10) { continue }
        marks[markKey] = resetAt * 10 + Int64(level)
        let deficit = Int(max(0, -w.headroomPercent).rounded())
        let etaText = Date(timeIntervalSince1970: Double(w.exhaustionAt!) / 1000)
            .formatted(date: .omitted, time: .shortened)
        alerts.append(LimitAlert(
            windowKey: key,
            title: "GLM \(key.contains("five") ? "5h" : "weekly"): не уложимся\(suffix)",
            body: "кончится ~\(etaText) · не хватит \(deficit)%"))
    }
    // Imminent: любой осмысленный (не overflow, не idle) вердикт с ETA < H минут.
    // Спека §7: ключа нет → дефолт 20 мин (0 явно выключает).
    if (config.imminentMinutes ?? 20) > 0, hasActive {
        for (key, w) in [("predict:five", f.fiveHours), ("predict:week", f.weekly)] {
            guard let w, w.verdict != .overflow, w.verdict != .idle,
                  let eta = etaMinutes(w), eta > 0,
                  eta < (config.imminentMinutes ?? 20), let resetAt = w.resetAt else { continue }
            let markKey = "glm:\(key)"
            if marks[markKey] == resetAt * 10 + 9 { continue }
            marks[markKey] = resetAt * 10 + 9
            alerts.append(LimitAlert(windowKey: key,
                                     title: "GLM \(key.contains("five") ? "5h" : "weekly"): исчерпание через \(Int(eta.rounded())) мин",
                                     body: "при текущем темпе"))
        }
    }
    return (alerts, marks)
}

/// Спайк-детект (этап 3): активная сессия с большим абсолютным темпом
/// (>= minTokensPerHour) жжёт в multiplier раз больше недельной EMA-ставки.
/// multiplier 0 выключает; cooldown гасит повторы на сессию (маркер —
/// unix-секунда последнего алерта). Некалиброванная/нулевая неделя молчит:
/// базы для сравнения нет.
func spikeAlerts(forecast: GLMForecast?,
                 notified: [String: Int64], now: Date,
                 multiplier: Double = 8,
                 cooldownSeconds: Int64 = 30 * 60,
                 minTokensPerHour: Double = 1_000_000)
    -> (alerts: [LimitAlert], notified: [String: Int64]) {
    var marks = notified
    var alerts: [LimitAlert] = []
    guard multiplier > 0, let f = forecast,
          let weekly = f.weekly,
          weekly.verdict != .calibrating,
          weekly.rateCreditsPerHour > 0 else {
        return (alerts, marks)
    }
    let baseline = weekly.rateCreditsPerHour
    let nowSec = Int64(now.timeIntervalSince1970)
    for a in f.agents {
        guard a.active, a.creditsPerHour > 0,
              a.tokensPerHour >= minTokensPerHour,
              a.creditsPerHour / baseline >= multiplier else { continue }
        let markKey = "glm:spike:\(a.id ?? a.name)"
        if let last = marks[markKey], nowSec - last < cooldownSeconds { continue }
        marks[markKey] = nowSec
        let ratio = a.creditsPerHour / baseline
        alerts.append(LimitAlert(
            windowKey: "spike",
            title: "GLM: всплеск — \(a.name)",
            body: String(format: "%.1f× недельного темпа · %@ ток/ч",
                         ratio, ForecastWindow.compactTokens(a.tokensPerHour))))
    }
    return (alerts, marks)
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
        guard let w = window, let pct = displayUsagePercent(w.utilization) else { continue }
        if w.utilization < limitAlertThreshold {
            marks[markKey] = nil
            continue
        }
        let mark = w.resetUnix ?? 0
        guard marks[markKey] != mark else { continue }
        marks[markKey] = mark
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

/// Codex-предиктивные алерты (этап 2): та же лестница, что у GLM, но по
/// окнам `CodexForecast` и без гейта «есть активная сессия» — rate-limit
/// snapshot авторитетен сам по себе. Идентичность маркера включает
/// percent-escaped bucketID, слот, resetAt, вердикт и уровень: повторные
/// снапшоты одного окна молчат, новое окно уведомляет снова. Stale,
/// calibrating и idle молчат; reset/ETA недоступны — тоже.
func codexPredictiveAlerts(forecast: CodexForecast?,
                           config: GLMForecastConfigSection,
                           notified: [String: Int64], now: Date)
    -> (alerts: [LimitAlert], notified: [String: Int64]) {
    var marks = notified
    var alerts: [LimitAlert] = []
    guard let forecast else { return (alerts, marks) }
    let nowMs = Int64(now.timeIntervalSince1970 * 1000)
    func etaMinutes(_ window: CodexWindowForecast) -> Double? {
        window.exhaustionAt.map { (Double($0) - Double(nowMs)) / 60_000 }
    }
    func escaped(_ bucketID: String) -> String {
        bucketID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? bucketID
    }
    for window in forecast.windows {
        guard !window.stale,
              let resetAt = window.resetAt,
              let eta = etaMinutes(window), eta > 0 else { continue }
        let base = "codex:predict:\(escaped(window.bucketID)):\(window.windowKey.rawValue):\(resetAt):\(window.verdict.rawValue)"
        let label = window.label.isEmpty ? window.bucketID : window.label
        switch window.verdict {
        case .overflow:
            let level: Int
            let suffix: String
            if eta < 15 { level = 2; suffix = " (критично)" }
            else if eta < 60 { level = 1; suffix = "" }
            else { level = 0; suffix = "" }
            let markKey = "\(base):\(level)"
            guard marks[markKey] == nil else { continue }
            marks[markKey] = nowMs
            let deficit = Int(max(0, -window.headroomPercent).rounded())
            let etaText = Date(timeIntervalSince1970: Double(window.exhaustionAt!) / 1000)
                .formatted(date: .omitted, time: .shortened)
            alerts.append(LimitAlert(
                windowKey: "codex:\(window.windowKey.rawValue)",
                title: "Codex \(label): не уложимся\(suffix)",
                body: "кончится ~\(etaText) · не хватит \(deficit)%"))
        case .tight, .fits:
            let imminent = config.imminentMinutes ?? 20
            guard imminent > 0, eta < imminent else { continue }
            let markKey = "\(base):imminent"
            guard marks[markKey] == nil else { continue }
            marks[markKey] = nowMs
            alerts.append(LimitAlert(
                windowKey: "codex:\(window.windowKey.rawValue)",
                title: "Codex \(label): исчерпание через \(Int(eta.rounded())) мин",
                body: "при текущем темпе"))
        case .calibrating, .idle, .underuse:
            continue
        }
    }
    return (alerts, marks)
}
