import SwiftUI
import CoveyKit

/// Компактные форматтеры аналитики PM.
enum PMFormat {
    static func tokens(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.0fk", v / 1_000) }
        return String(format: "%.0f", v)
    }
    static func usd(_ v: Double) -> String { String(format: "$%.2f", v) }
    static func minutes(_ m: Int) -> String {
        if m < 60 { return "\(m)m" }
        let h = m / 60, rem = m % 60
        return rem == 0 ? "\(h)h" : "\(h)h \(rem)m"
    }
}

/// Вкладка Analytics режима Projects (spec §9.1): сводка проекта, модели,
/// диапазон 7/30/all. Карточки — стили Tokens, паттерн Forecast-карточек.
struct PMAnalyticsView: View {
    let model: AppModel
    let projectID: String?
    @State private var rangeDays: Int = 30
    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Range", selection: $rangeDays) {
                    Text("7d").tag(7)
                    Text("30d").tag(30)
                    Text("All").tag(-1)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                if let s = model.pm.analytics?.project {
                    summaryCard(s)
                    if !s.byModel.isEmpty { modelsCard(s) }
                } else {
                    Text("No analytics yet").foregroundStyle(tk.t3)
                }
            }
            .padding()
        }
        .task(id: rangeDays) {
            model.pm.analyticsRangeDays = rangeDays
            await model.pm.loadAnalytics(projectID: projectID)
        }
    }

    private func summaryCard(_ s: PMProjectAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Summary").font(.headline).foregroundStyle(tk.t1)
            HStack(spacing: 16) {
                stat("Tasks", "\(s.tasksDone) done · \(s.tasksFailed) failed · \(s.taskCounts["in_progress"] ?? 0) open")
                stat("Active", PMFormat.minutes(s.totals.activeMinutes))
                stat("Tokens", PMFormat.tokens(s.totals.input + s.totals.output
                    + s.totals.cacheCreation + s.totals.cacheRead))
                stat("Cost", s.costUSD.map(PMFormat.usd) ?? "no price")
            }
        }
        .padding(12)
        .background(tk.surf2)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.r))
    }

    private func modelsCard(_ s: PMProjectAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Models").font(.headline).foregroundStyle(tk.t1)
            ForEach(s.byModel, id: \.model) { m in
                HStack {
                    Text(m.model).foregroundStyle(tk.t1)
                    Spacer()
                    Text("\(PMFormat.tokens(m.tokens.input + m.tokens.output)) tok · "
                       + "\(PMFormat.minutes(m.tokens.activeMinutes)) · "
                       + (m.costUSD.map(PMFormat.usd) ?? "no price")
                       + " · ✅\(m.tasksDone) ❌\(m.tasksFailed)")
                        .font(.caption).foregroundStyle(tk.t3)
                }
            }
        }
        .padding(12)
        .background(tk.surf2)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.r))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundStyle(tk.t3)
            Text(value).foregroundStyle(tk.t1)
        }
    }
}
