import SwiftUI
import CoveyKit

/// Чистый маппинг окна прогноза Codex в строку карточки (Task 5): все
/// форматы — вне SwiftUI-тела, тестируется без отрисовки. ID карточки —
/// `codex:<bucketID>:<windowKey>`; пустая метка падает на bucketID; stale
/// прячет exhaustion (данные устарели — живого ETA не показываем).
struct CodexForecastWindowPresentation: Equatable {
    var id: String
    var title: String
    var slot: String
    var bucketID: String
    var verdict: CodexForecastVerdict
    var status: String
    var used: String
    var projected: String
    var headroom: String
    var rate: String
    var reset: String
    var exhaustion: String?
    var band: String?
    var samples: String
    var staleBadge: Bool
    var isError: Bool
}

func codexForecastPresentations(_ forecast: CodexForecast?,
                                now: Date = Date()) -> [CodexForecastWindowPresentation] {
    guard let forecast else { return [] }
    return forecast.windows.map { window in
        let title = window.label.isEmpty ? window.bucketID : window.label
        let stale = window.stale
        let band: String?
        if let p50 = window.projectedP50, let p90 = window.projectedP90 {
            band = "p50 \(Int(p50.rounded()))% · p90 \(Int(p90.rounded()))%"
        } else {
            band = nil
        }
        func countdown(_ ms: Int64?) -> String {
            guard let ms else { return "—" }
            let minutes = max(0, Double(ms - Int64(now.timeIntervalSince1970 * 1000)) / 60_000)
            return "in " + ForecastEN.duration(minutes: minutes)
        }
        return CodexForecastWindowPresentation(
            id: "codex:\(window.bucketID):\(window.windowKey.rawValue)",
            title: title,
            slot: window.windowKey == .primary ? "primary" : "secondary",
            bucketID: window.bucketID,
            verdict: window.verdict,
            status: codexForecastStatusCopy(window),
            used: "\(Int(window.usedPercent.rounded()))%",
            projected: "\(Int(window.projectedPercent.rounded()))%",
            headroom: "\(Int(window.headroomPercent.rounded()))%",
            rate: window.ratePercentPerHour == 0
                ? "—" : String(format: "%.1f%%/h", window.ratePercentPerHour),
            reset: countdown(window.resetAt),
            exhaustion: stale ? nil : countdown(window.exhaustionAt),
            band: band,
            samples: "\(window.sampleCount) samples",
            staleBadge: stale,
            isError: window.verdict == .overflow || window.headroomPercent < 0)
    }
}

/// Копия статуса: три состояния обязаны различаться; stale — про свежесть,
/// не про вердикт.
private func codexForecastStatusCopy(_ window: CodexWindowForecast) -> String {
    if window.stale { return "stale" }
    switch window.verdict {
    case .calibrating: return "calibrating"
    case .idle: return "idle"
    case .overflow: return "overflow"
    case .tight: return "tight"
    case .underuse: return "underuse"
    case .fits: return "fits"
    }
}

/// Цвет вердикта прогноза Codex: общая шкала порогов.
func codexVerdictColor(_ verdict: CodexForecastVerdict, tk: Tokens) -> Color {
    switch verdict {
    case .overflow: return tk.err
    case .tight: return tk.warn
    case .calibrating: return tk.t3
    case .idle, .underuse, .fits: return tk.ok
    }
}

/// Карточка одного окна прогноза Codex: текущий/проекция/headroom, rate,
/// countdown'ы, полоса неопределённости и счётчик сэмплов. Stale приглушает
/// прогнозные значения, сохраняя последнее наблюдение.
struct CodexForecastCard: View {
    let card: CodexForecastWindowPresentation
    let tk: Tokens

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(card.title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tk.t1)
                Text(card.slot)
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .textCase(.uppercase)
                    .foregroundStyle(tk.t3)
                if card.staleBadge {
                    Text("stale")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .textCase(.uppercase)
                        .foregroundStyle(tk.warn)
                }
                Spacer()
                Text(card.status)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(codexVerdictColor(card.verdict, tk: tk))
            }
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                stat("used", card.used, color: card.isError ? tk.err : tk.t1)
                stat("projected", card.projected,
                     color: card.isError ? tk.err : tk.t2, dim: card.staleBadge)
                stat("headroom", card.headroom,
                     color: card.isError ? tk.err : tk.t2, dim: card.staleBadge)
                stat("rate", card.rate, color: tk.t2, dim: card.staleBadge)
            }
            HStack(spacing: 14) {
                stat("reset", card.reset, color: tk.t3)
                if let exhaustion = card.exhaustion {
                    stat("exhaustion", exhaustion, color: tk.t3, dim: card.staleBadge)
                }
                Spacer()
                if let band = card.band {
                    Text(band)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tk.t3)
                }
                Text(card.samples)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(tk.t4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tk.card)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.rLg))
        .overlay(RoundedRectangle(cornerRadius: Tokens.rLg).stroke(tk.bd2))
        .help("Codex rate-limit window \(card.bucketID) (\(card.slot)) — forecast from observed burn rate")
    }

    private func stat(_ name: String, _ value: String, color: Color,
                      dim: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .textCase(.uppercase)
                .foregroundStyle(tk.t4)
            Text(value)
                .font(.system(size: 13, design: .monospaced).monospacedDigit())
                .foregroundStyle(dim ? tk.t3 : color)
        }
    }
}
