import SwiftUI

/// Локальное «HH:mm» для ETA прогноза; один форматтер на процесс. Живёт здесь,
/// а не в файле рендера статус-айтема: строку прогноза читают и панель, и
/// строки под окнами GLM в limits overlay.
enum ForecastText {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// «5 окт, 10:05» — края домена графика: начало периода и сброс.
    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMMHmm")
        return f
    }()

    /// «6 окт» — дневные риски на оси 7d.
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()

    /// Прогноз окна GLM по метке чипа: «5h» → fiveHours, «7d» → weekly. Чужие
    /// метки (Claude/Codex) и отсутствующий прогноз строки не дают.
    static func glmWindowForecast(_ label: String, forecast: GLMForecast?) -> GLMWindowForecast? {
        switch label {
        case "5h": return forecast?.fiveHours
        case "7d": return forecast?.weekly
        default: return nil
        }
    }

    /// Одна строка прогноза под окном GLM (спека §6.2). nil — строки нет.
    static func forecastLine(_ w: GLMWindowForecast, label: String, now: Date) -> String? {
        switch w.verdict {
        case .idle: return nil
        case .calibrating: return "калибровка…"
        case .fits: return "влезаем, запас \(Int(max(0, w.headroomPercent).rounded()))%"
        case .tight: return "впритык, запас \(Int(max(0, w.headroomPercent).rounded()))%"
        case .overflow:
            let deficit = Int(max(0, -w.headroomPercent).rounded())
            let eta = w.exhaustionAt.map {
                "кончится ~\(time.string(from: Date(timeIntervalSince1970: Double($0) / 1000)))"
            } ?? "не успеваем"
            return "⚠ \(eta), не хватит \(deficit)%"
        case .underuse:
            return "можно грузить сильнее: к сбросу останется \(Int(max(0, w.headroomPercent).rounded()))%"
        }
    }
}

/// Чистая логика форматирования панели прогноза GLM (спека §6.3) — закреплена
/// юнит-тестами `ForecastWindowModelTests`.
enum ForecastWindow {
    /// «0.05000 · 3ч назад»; без фактора — «калибровка…», без давности — только значение.
    static func factorDescription(_ factor: Double?, calibratedAt: Date?, now: Date) -> String {
        guard let factor else { return "калибровка…" }
        let value = String(format: "%.5f", factor)
        guard let calibratedAt else { return value }
        let minutes = max(0, Int((now.timeIntervalSince(calibratedAt) / 60).rounded()))
        if minutes < 60 { return "\(value) · \(minutes)м назад" }
        let hours = minutes / 60
        if hours < 24 { return "\(value) · \(hours)ч назад" }
        return "\(value) · \(hours / 24)д назад"
    }

    /// Суффиксы имени агента: «внешняя» и/или «субагенты» (расход в основном
    /// в субагентах — доля > 0.5).
    static func agentSuffix(external: Bool, sidechainShare: Double) -> String {
        var parts: [String] = []
        if external { parts.append("внешняя") }
        if sidechainShare > 0.5 { parts.append("субагенты") }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }

    /// «пик до 18:00 (через 2ч40м)» / «офф-пик, пик в 14:00 (через 2ч40м)» —
    /// локальный тайзон через ForecastText.time.
    static func regimeHeader(peakNow: Bool, nextFlipAt: Date?, now: Date) -> String {
        guard let nextFlipAt else { return peakNow ? "пик" : "офф-пик" }
        let time = ForecastText.time.string(from: nextFlipAt)
        let left = duration(from: now, to: nextFlipAt)
        return peakNow ? "пик до \(time) (через \(left))"
                       : "офф-пик, пик в \(time) (через \(left))"
    }

    /// «2ч40м»: до часа — только минуты. Округляем к минуте, чтобы дрейф
    /// Date() между двумя замерами не съедал последнюю.
    static func duration(from start: Date, to end: Date) -> String {
        let minutes = max(0, Int((start.distance(to: end) / 60).rounded()))
        let hours = minutes / 60
        return hours > 0 ? "\(hours)ч\(minutes % 60)м" : "\(minutes)м"
    }

    /// Точки серии внутри окна: от сброса минус длительность (пока окно не
    /// известно — от now). Серии приходят за 7д, панель показывает только окно.
    static func trimmed(_ series: [GLMSeriesPoint], resetAt: Int64?, now: Date,
                        hours: Double) -> [GLMSeriesPoint] {
        let end = resetAt ?? Int64(now.timeIntervalSince1970 * 1000)
        return series.filter { $0.t >= end - Int64(hours * 3600 * 1000) }
    }

    /// «980» / «12.3k» / «1.2M» — компактные токены в колонках.
    static func compactTokens(_ value: Double) -> String {
        switch abs(value) {
        case ..<1_000: return String(format: "%.0f", value)
        case ..<1_000_000: return String(format: "%.1fk", value / 1_000)
        default: return String(format: "%.1fM", value / 1_000_000)
        }
    }
}

/// Панель прогноза GLM (спека §6.3): режим, графики обоих окон (факт +
/// пунктирная проекция к projected), таблица агентов, модели по типам токенов,
/// статус калибровки. Открывается action link «Прогноз…» в limits overlay —
/// второй стеклянной карточкой поверх него, поэтому ширина подгоняется под
/// ширину карточки оверлея.
struct ForecastWindowView: View {
    let forecast: GLMForecast?
    /// Ширина карточки оверлея: панель проектируется под неё, а не под старую
    /// ширину поповера.
    var width: CGFloat = 276
    /// nil — крестика нет (панель открыта там, где рядом есть «Прогноз…»).
    var onClose: (() -> Void)? = nil

    @State private var contentHeight: CGFloat = 320

    var body: some View {
        TimelineView(.everyMinute) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let forecast {
                        regime(forecast, now: context.date)
                        chartSection("Окно 5ч", series: forecast.fiveHourSeries,
                                     window: forecast.fiveHours, hours: 5, now: context.date)
                        chartSection("Окно 7д", series: forecast.weeklySeries,
                                     window: forecast.weekly, hours: 7 * 24, now: context.date)
                        agents(forecast)
                        models(forecast)
                        calibration(forecast, now: context.date)
                    } else {
                        Text("Прогноз появится после первого опроса GLM")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // Меряем контент, не сам ScrollView: ScrollView «жадный» — его
                // высота равна proposal, и измерение снаружи каждый проход
                // съедало padding, схлопывая панель. Контент внутри получает
                // nil-высоту и растёт по содержимому, как в LimitsPanel.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.primary)
        .padding(12)
        .frame(width: width,
               height: min(contentHeight, max(200, (NSScreen.main?.visibleFrame.height ?? 700) - 120)))
    }

    // MARK: - Режим

    private func regime(_ forecast: GLMForecast, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(ForecastWindow.regimeHeader(
                peakNow: forecast.peakNow,
                nextFlipAt: forecast.nextFlipAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                now: now))
                .font(.system(size: 12, weight: .semibold))
            if let onClose {
                Spacer()
                OverlayActionLink(title: "Скрыть прогноз", action: onClose)
            }
        }
    }

    // MARK: - Графики

    private func chartSection(_ title: String, series: [GLMSeriesPoint],
                              window: GLMWindowForecast?, hours: Double, now: Date) -> some View {
        let resetAt = window?.resetAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        let resetLabel = resetAt.map { "сброс через \(ForecastWindow.duration(from: now, to: $0))" }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle(title)
                Spacer()
                if let resetLabel {
                    Text(resetLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            windowChart(title: title, series: series, window: window, hours: hours, now: now)
            if let window,
               let line = ForecastText.forecastLine(window, label: title, now: now) {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(verdictColor(window.verdict))
            }
        }
    }

    /// Факт серии сплошной линией + пунктир от последней точки к projected
    /// на сбросе окна. Ось Y — кредиты, X — время.
    @ViewBuilder
    private func windowChart(title: String, series: [GLMSeriesPoint],
                             window: GLMWindowForecast?, hours: Double,
                             now: Date) -> some View {
        let points = ForecastWindow.trimmed(series, resetAt: window?.resetAt,
                                            now: now, hours: hours)
        if points.count >= 2 {
            Canvas { context, size in
                let last = points[points.count - 1]
                let startT = Double(points[0].t)
                let endT = Double(max(last.t, window?.resetAt ?? last.t))
                var usedMax = points.map(\.used).max() ?? 0
                if let window { usedMax = max(usedMax, window.projected) }
                let yMax = max(usedMax * 1.08, 1e-9)
                func point(_ t: Int64, _ used: Double) -> CGPoint {
                    CGPoint(x: (Double(t) - startT) / max(1, endT - startT) * size.width,
                            y: (1 - used / yMax) * size.height)
                }
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: size.height))
                baseline.addLine(to: CGPoint(x: size.width, y: size.height))
                context.stroke(baseline, with: .color(.secondary.opacity(0.25)), lineWidth: 1)

                var fact = Path()
                fact.move(to: point(points[0].t, points[0].used))
                for p in points.dropFirst() { fact.addLine(to: point(p.t, p.used)) }
                context.stroke(fact, with: .color(.primary.opacity(0.75)), lineWidth: 1.5)

                if let window, let reset = window.resetAt,
                   Double(reset) > Double(last.t),
                   window.verdict != .idle, window.verdict != .calibrating {
                    var projection = Path()
                    projection.move(to: point(last.t, last.used))
                    projection.addLine(to: point(reset, window.projected))
                    context.stroke(projection, with: .color(verdictColor(window.verdict)),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .frame(height: 88)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("График использования, \(title)")
        } else {
            Text("нет данных")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func verdictColor(_ verdict: GLMForecastVerdict) -> Color {
        switch verdict {
        case .overflow: return Color(nsColor: nativeUsageColor(.err))
        case .tight: return Color(nsColor: nativeUsageColor(.warn))
        case .fits, .underuse: return Color(nsColor: nativeUsageColor(.ok))
        case .idle, .calibrating: return .secondary
        }
    }

    // MARK: - Агенты

    private func agents(_ forecast: GLMForecast) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Агенты")
            if forecast.agents.isEmpty {
                Text("нет активных агентов")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Grid(horizontalSpacing: 6, verticalSpacing: 4) {
                    GridRow {
                        Text("агент")
                        Text("активность")
                        headerCell("ток/ч").gridColumnAlignment(.trailing)
                        headerCell("кред/ч").gridColumnAlignment(.trailing)
                        headerCell("доля").gridColumnAlignment(.trailing)
                        headerCell("бюджет").gridColumnAlignment(.trailing)
                    }
                    ForEach(forecast.agents, id: \.stableID) { agent in
                        GridRow {
                            // Движок уже свернул долю субагентов в признак (>0.5),
                            // поэтому в суффикс уходит 1/0.
                            Text(agent.name + ForecastWindow.agentSuffix(
                                external: agent.external,
                                sidechainShare: agent.isSidechainMarked ? 1 : 0))
                                .lineLimit(1)
                            Text(agent.active ? "да" : "—")
                                .foregroundStyle(agent.active ? Color.primary : Color.secondary)
                            Text(ForecastWindow.compactTokens(agent.tokensPerHour))
                            Text(String(format: "%.2f", agent.creditsPerHour))
                            Text("\(Int(agent.sharePercent.rounded()))%")
                            Text(agent.budgetMinutes.map { "\(Int($0.rounded()))м" } ?? "—")
                        }
                    }
                }
                .font(.caption.monospacedDigit())
            }
        }
    }

    // MARK: - Модели

    private func models(_ forecast: GLMForecast) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Модели")
            if forecast.models.isEmpty {
                Text("нет данных")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Grid(horizontalSpacing: 6, verticalSpacing: 3) {
                    GridRow {
                        Text("модель")
                        Text("")
                        headerCell("in").gridColumnAlignment(.trailing)
                        headerCell("out").gridColumnAlignment(.trailing)
                        headerCell("кэш+").gridColumnAlignment(.trailing)
                        headerCell("кэш").gridColumnAlignment(.trailing)
                    }
                    ForEach(forecast.models, id: \.model) { model in
                        GridRow {
                            Text(model.model).lineLimit(1)
                            Text("окно").foregroundStyle(.secondary)
                            tokenCells(model.window)
                        }
                        GridRow {
                            Text("")
                            Text("час").foregroundStyle(.secondary)
                            tokenCells(model.lastHour)
                        }
                    }
                }
                .font(.caption.monospacedDigit())
            }
        }
    }

    @ViewBuilder
    private func tokenCells(_ usage: GLMTokenUsage) -> some View {
        Text(ForecastWindow.compactTokens(usage.input))
        Text(ForecastWindow.compactTokens(usage.output))
        Text(ForecastWindow.compactTokens(usage.cacheCreation))
        Text(ForecastWindow.compactTokens(usage.cacheRead))
    }

    // MARK: - Калибровка

    private func calibration(_ forecast: GLMForecast, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Калибровка")
            calibrationRow("пик", factor: forecast.factorPeak,
                           calibratedAt: forecast.factorPeakAt, now: now)
            calibrationRow("офф-пик", factor: forecast.factorOffPeak,
                           calibratedAt: forecast.factorOffPeakAt, now: now)
        }
    }

    private func calibrationRow(_ label: String, factor: Double?,
                                calibratedAt: Int64?, now: Date) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(ForecastWindow.factorDescription(factor, calibratedAt: calibratedAt.map {
                Date(timeIntervalSince1970: Double($0) / 1000)
            }, now: now))
            .font(.caption.monospacedDigit())
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold))
    }

    /// Стиль применяется к ячейке, не к GridRow: модификаторы на самой строке
    /// ломают её раскладку в Grid.
    private func headerCell(_ title: String) -> some View {
        Text(title).foregroundStyle(.secondary)
    }
}
