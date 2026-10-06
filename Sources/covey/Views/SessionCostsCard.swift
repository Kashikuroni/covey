import SwiftUI
import CoveyKit

/// Журнал стоимости сессий (этап 2): пожизненные тоталы токенов по сессиям
/// из стора — живые и заархивированные, топ по расходу. ~cr — оценка
/// фактором текущего тарифного режима (без калибровки — только токены).
struct SessionCostsCard: View {
    let entries: [ForecastSessionCostEntry]
    /// Фактор текущего тарифного режима GLM — применяется ТОЛЬКО к GLM-долям
    /// строк; GPT-тоталы в кредиты не переводятся.
    let glmFactor: Double?
    let tk: Tokens
    let projectParts: (String) -> (project: String, branch: String?)?
    let settings: DashboardSettings

    enum Span: CaseIterable {
        case week, month, all
        var days: Int? { self == .week ? 7 : self == .month ? 30 : nil }
        var title: String { self == .week ? "7d" : self == .month ? "30d" : "all" }
    }

    @State private var span: Span = .week

    private var rows: [ForecastSessionCostEntry] {
        let now = Date()
        return entries.filter { e in
            guard let days = span.days else { return true }
            let last = Date(timeIntervalSince1970: Double(e.record.lastSeen) / 1000)
            return now.timeIntervalSince(last) <= Double(days) * 86_400
        }
    }

    private func tokens(_ e: ForecastSessionCostEntry) -> Double {
        e.record.byModel.values.reduce(0, +)
    }

    /// $ за сессию: Σ по компонентам биллинга × прайс модели из реестра
    /// (in/cached/storage/out раздельно — output дороже input в разы).
    /// Показываем, если хоть у одной модели задан прайс.
    private func dollars(_ e: ForecastSessionCostEntry) -> String? {
        var sum = 0.0
        var any = false
        for (model, usage) in e.record.usage ?? [:] {
            if let c = settings.cost(model: model, usage: usage) {
                sum += c
                any = true
            }
        }
        guard any else { return nil }
        return "~$" + String(format: "%.2f", sum)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("session costs")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .textCase(.uppercase)
                Text("· lifetime tokens per session").foregroundStyle(tk.t3)
                Spacer()
                ForEach(Span.allCases, id: \.title) { s in
                    Button {
                        span = s
                    } label: {
                        Text(s.title)
                            .font(.system(size: 9, weight: span == s ? .semibold : .regular,
                                           design: .monospaced))
                            .foregroundStyle(span == s ? tk.t1 : tk.t3)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(span == s ? tk.surf3 : Color.clear))
                            .overlay(Capsule().stroke(tk.bd2))
                    }
                    .buttonStyle(.plain)
                }
            }
            if rows.isEmpty {
                Text("no sessions in range").font(.caption).foregroundStyle(tk.t3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(rows.prefix(20).enumerated()), id: \.element.record.firstSeen) { i, e in
                    row(e, divider: i < min(rows.count, 20) - 1)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Tokens.rLg).fill(tk.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.rLg).stroke(tk.bd2))
    }

    private func row(_ e: ForecastSessionCostEntry, divider: Bool) -> some View {
        HStack(spacing: 0) {
            // Имя: проект как в списке сессий (для путей), иначе как есть.
            HStack(spacing: 6) {
                if let parts = projectParts(e.name) {
                    Text(parts.project).foregroundStyle(tk.t1)
                    if let branch = parts.branch, !branch.isEmpty {
                        Text(branch).foregroundStyle(tk.t3).lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    Text(e.name).foregroundStyle(tk.t1)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text(e.live ? "live" : "done")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .textCase(.uppercase)
                    .foregroundStyle(e.live ? tk.ok : tk.t3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(dates(e))
                .foregroundStyle(tk.t3)
                .frame(width: 150, alignment: .leading)
            Text(ForecastWindow.compactTokens(tokens(e)))
                .frame(width: 82, alignment: .trailing)
            Text(estimatedCr(e))
                .foregroundStyle(tk.t2)
                .frame(width: 92, alignment: .trailing)
            Text(dollars(e) ?? "—")
                .frame(width: 74, alignment: .trailing)
            Text(topModel(e))
                .foregroundStyle(tk.t3)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 120, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(tk.bd2).frame(height: 1) }
        }
        .help(help(e))
    }

    private func dates(_ e: ForecastSessionCostEntry) -> String {
        let f = ForecastText.day
        let first = f.string(from: Date(timeIntervalSince1970: Double(e.record.firstSeen) / 1000))
        let last = f.string(from: Date(timeIntervalSince1970: Double(e.record.lastSeen) / 1000))
        return first == last ? first : "\(first) – \(last)"
    }

    private func estimatedCr(_ e: ForecastSessionCostEntry) -> String {
        sessionEstimatedGLMCredits(e, factor: glmFactor)
    }

    private func topModel(_ e: ForecastSessionCostEntry) -> String {
        e.record.byModel.max { $0.value < $1.value }?.key ?? "—"
    }

    private func help(_ e: ForecastSessionCostEntry) -> String {
        let models = e.record.byModel.sorted { $0.value > $1.value }
            .map { "\($0.key): \(ForecastWindow.compactTokens($0.value))" }
            .joined(separator: "\n")
        let base = e.name + (e.record.external ? " · external" : "")
        return base + "\n" + models
    }
}
