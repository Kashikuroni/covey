import SwiftUI
import CoveyKit

// MARK: - English copy for the full-window mode
//
// The compact overlay keeps its Russian copy (pinned by ForecastWindowModel
// tests); this mode follows the design handoff, which specifies English UI.

// MARK: - Provider-neutral presentation (чистые helpers — тестируются без SwiftUI)

/// GLM/z.ai-модель по имени (зеркало CoveydCore-проверки на стороне приложения).
func isGLMModelName(_ model: String) -> Bool {
    let m = model.lowercased()
    return m.contains("glm") || m.contains("zai")
}

/// Начиная с какой ширины окна карточки аналитики встают парами в строку.
/// Ниже — «ноутбучная» раскладка: каждая карточка на всю ширину, таблицы
/// не сжимаются в вертикальные пилюли.
let pairedAnalyticsRowMinWidth: CGFloat = 1600

/// Широкая раскладка: пары карточек в строку; узкая — стек по одной.
func analyticsUsesPairedRows(_ width: CGFloat) -> Bool {
    width >= pairedAnalyticsRowMinWidth
}

/// Какие секции страницы Forecast показывать: GLM-часть (окна/onboarding/off/
/// ожидание) и аналитика независимы — GPT-данные живут без GLM.
struct ForecastContentState: Equatable {
    var showsGLMWindows = false
    var showsGLMOnboarding = false
    var showsGLMOff = false
    var showsGLMWaiting = false
    var showsAnalytics = false
    var showsGPTModels = false
}

func forecastContentState(glmEnabled: Bool, glmAPIKeyMissing: Bool = false,
                          glmForecast: GLMForecast?,
                          analytics: ForecastAnalytics?) -> ForecastContentState {
    var state = ForecastContentState()
    if !glmEnabled {
        state.showsGLMOff = true
    } else if glmAPIKeyMissing {
        state.showsGLMOnboarding = true
    }
    if glmEnabled, let forecast = glmForecast,
        forecast.fiveHours != nil || forecast.weekly != nil {
        state.showsGLMWindows = true
    } else if glmEnabled, !glmAPIKeyMissing {
        state.showsGLMWaiting = true
    }
    let analytics = analytics ?? ForecastAnalytics()
    state.showsAnalytics = !(analytics.models.isEmpty && analytics.modelDaily.isEmpty
        && analytics.hourly.isEmpty && analytics.modelHourly.isEmpty
        && analytics.sessions.isEmpty && analytics.sessionCosts.isEmpty)
    state.showsGPTModels = analytics.sessions.contains { $0.source == .codex }
    return state
}

/// Строка таблицы сессий: source-бейдж и опциональные квота-поля (для GPT
/// и обычных Claude-моделей кредиты/бюджет — прочерк).
func sessionPresentation(_ session: ForecastSessionUsage)
    -> (source: String, credits: String, budget: String) {
    let source = session.source == .codex ? "Codex" : "Claude Code"
    let credits = session.creditsPerHour.map { String(format: "%.1f", $0) } ?? "—"
    let budget = session.budgetMinutes.map { ForecastEN.duration(minutes: $0) } ?? "—"
    return (source, credits, budget)
}

/// Команда для AgentIcon по источнику сессии (иконки как в панели сессий).
func agentIconCommand(for source: ForecastUsageSource) -> String {
    source == .codex ? "codex" : "claude"
}

/// Строка таблицы агентов из провайдер-нейтральной аналитики.
struct AgentRow: Identifiable, Equatable {
    let id: String
    let name: String
    let source: ForecastUsageSource
    let external: Bool
    let active: Bool
    let tokensPerHour: Double
    let creditsPerHour: Double?
    let sharePercent: Double
    let budgetMinutes: Double?
    let cacheHit: Double?
    let contextTokens: Double?
    let contextDeltaPerTurn: Double?
}

func agentRows(_ sessions: [ForecastSessionUsage]) -> [AgentRow] {
    let total = sessions.reduce(0.0) { $0 + $1.tokensPerHour }
    return sessions.map { session in
        AgentRow(id: session.id, name: session.name, source: session.source,
                 external: session.external, active: session.active,
                 tokensPerHour: session.tokensPerHour,
                 creditsPerHour: session.creditsPerHour,
                 sharePercent: total > 0 ? session.tokensPerHour / total * 100 : 0,
                 budgetMinutes: session.budgetMinutes,
                 cacheHit: session.cacheHit,
                 contextTokens: session.contextTokens,
                 contextDeltaPerTurn: session.contextDeltaPerTurn)
    }
}

/// Оценка GLM-кредитов записи сессии: фактор множит ТОЛЬКО GLM-модели —
/// GPT-тотал никогда не переводится в кредиты z.ai.
func sessionEstimatedGLMCredits(_ entry: ForecastSessionCostEntry,
                                factor: Double?) -> String {
    guard let factor else { return "—" }
    let glmTokens = entry.record.byModel
        .filter { isGLMModelName($0.key) }
        .values.reduce(0, +)
    return "~" + ForecastEN.credits(glmTokens * factor) + " cr"
}

enum ForecastEN {
    /// «2ч40м» → "2h 40m"; сутки и больше — "3d 18h" / "3d"; под часом — минуты.
    static func duration(from start: Date, to end: Date) -> String {
        let minutes = max(0, Int((start.distance(to: end) / 60).rounded()))
        let days = minutes / (24 * 60)
        if days > 0 {
            let hours = minutes % (24 * 60) / 60
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        let hours = minutes / 60
        return hours > 0 ? "\(hours)h \(minutes % 60)m" : "\(minutes)m"
    }

    static func resetsIn(_ reset: Date?, now: Date) -> String? {
        guard let reset else { return nil }
        return "resets in \(duration(from: now, to: reset))"
    }

    static func headroom(_ percent: Double) -> String {
        String(format: "%+.1f%%", percent)
    }

    static func pct(_ percent: Double) -> String {
        String(format: "%.0f%%", percent)
    }

    /// "0.05000 · 3h ago"; no factor yet — "calibrating…".
    static func factor(_ factor: Double?, calibratedAt: Date?, now: Date) -> String {
        guard let factor else { return "calibrating…" }
        let value = String(format: "%.5f", factor)
        guard let calibratedAt else { return value }
        let minutes = max(0, Int((now.timeIntervalSince(calibratedAt) / 60).rounded()))
        if minutes < 60 { return "\(value) · \(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(value) · \(hours)h ago" }
        return "\(value) · \(hours / 24)d ago"
    }

    static func verdictChip(_ verdict: GLMForecastVerdict) -> String {
        switch verdict {
        case .calibrating: return "calibrating…"
        default: return verdict.rawValue
        }
    }

    /// "980" / "12.3k" — compact credit counts with fixed grouping.
    static func credits(_ value: Double) -> String {
        if value >= 1000 {
            return NumberFormatter.localizedString(from: NSNumber(value: value.rounded()),
                                                   number: .decimal)
        }
        if value >= 100 { return String(Int(value.rounded())) }
        return String(format: "%.1f", value)
    }

    /// "/Users/me/path" → "~/path": $HOME collapses to "~" for display; the
    /// full path stays in the row tooltip.
    static func tildePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home + "/") else { return path == home ? "~" : path }
        return "~" + String(path.dropFirst(home.count))
    }
}

/// The full-window Forecast mode (design handoff:
/// docs/design_handoff_forecast_window): a compact provider strip, the GLM
/// regime band, two window cards with real charts, agents and models tables,
/// settings. The top bar — segment switch, limits chip, clock — belongs to
/// `TopBar` and is deliberately untouched.
struct ForecastModeView: View {
    let model: AppModel
    /// Ширина вьюпорта: решает, пары карточек в строку или стек.
    @State private var analyticsWidth: CGFloat = 0

    private var settings: DashboardSettings { model.dashboardSettings }
    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        TimelineView(.everyMinute) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Провайдеры — в модалке (клик по часам), настройки
                    // дашборда — шторкой из топбара. GLM-секция и аналитика
                    // независимы: GPT-данные показываются без GLM.
                    let state = forecastContentState(
                        glmEnabled: model.glmUsageEnabled,
                        glmAPIKeyMissing: model.glmAPIKeyStatus == .missing && model.glmQuota == nil,
                        glmForecast: model.glmForecast,
                        analytics: model.forecastAnalytics)
                    if state.showsGLMOff {
                        forecastOff
                    }
                    if state.showsGLMOnboarding {
                        onboarding
                    }
                    if state.showsGLMWindows {
                        windowCards(forecast: model.glmForecast, now: context.date)
                    }
                    if state.showsGLMWaiting {
                        emptyCard("No forecast yet — it appears after the first GLM poll")
                    }
                    if state.showsAnalytics, let analytics = model.forecastAnalytics {
                        analyticsArea(analytics, now: context.date)
                    }
                    // Секция Codex независима от GLM: окна rate-limit видны,
                    // даже когда GLM выключен или без ключа.
                    if let codexForecast = model.codexForecast,
                       !codexForecast.windows.isEmpty {
                        codexForecastArea(codexForecast, now: context.date)
                    }
                    settingsFooter
                }
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Модели, встреченные в метриках, регистрируются в реестре
            // (панель настроек строится по нему).
            .task(id: knownModelsKey) {
                settings.migrateLegacyColors(knownModels)
                settings.ensureAll(knownModels)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(tk.t1)
        // Ширина вьюпорта решает: пары карточек в строку или стек.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            analyticsWidth = width
        }
    }

    /// Все модели, встреченные в текущих метриках (таблица, дневные вёдра,
    /// журнал сессий) — ключ для перерегистрации при изменении набора.
    private var knownModels: [String] {
        guard let analytics = model.forecastAnalytics else { return [] }
        var all = Set(analytics.models.map(\.model))
        for day in analytics.modelDaily {
            all.formUnion(day.models.keys)
        }
        for entry in analytics.sessionCosts {
            all.formUnion(entry.record.byModel.keys)
        }
        return all.sorted()
    }

    private var knownModelsKey: String {
        knownModels.joined(separator: "\n")
    }

    // MARK: - Codex quota forecast

    /// Сетка карточек по окнам прогноза Codex — по одному на видимый слот
    /// каждого bucket-а.
    private func codexForecastArea(_ forecast: CodexForecast, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Codex rate limits", hint: "observed burn forecast")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(codexForecastPresentations(forecast, now: now), id: \.id) { card in
                    CodexForecastCard(card: card, tk: tk)
                }
            }
        }
    }

    // MARK: - Forecast area

    /// GLM-окна — отдельная секция (сетка 2×3 начиналась с них).
    private func windowCards(forecast: GLMForecast?, now: Date) -> some View {
        HStack(alignment: .top, spacing: 10) {
            windowCard("5h", window: forecast?.fiveHours,
                       series: forecast?.fiveHourSeries ?? [], hours: 5,
                       sliding: true, now: now)
            windowCard("7d", window: forecast?.weekly,
                       series: forecast?.weeklySeries ?? [], hours: 24 * 7,
                       sliding: false, now: now, extraStats: [
                           ("cache hit", weightedCacheHit(model.forecastAnalytics?.models ?? [])),
                       ])
        }
    }

    /// Аналитика: столбцы/теплокарта, таблицы, spend, журнал — из
    /// провайдер-нейтрального `forecastAnalytics`. Графики всегда парой —
    /// на ноутбуке им места хватает; адаптив нужен только таблицам:
    /// на узком окне каждая на всю ширину, иначе колонки сжимаются
    /// в вертикальные пилюли.
    private func analyticsArea(_ analytics: ForecastAnalytics, now: Date) -> some View {
        let paired = analyticsUsesPairedRows(analyticsWidth)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if !analytics.modelDaily.isEmpty {
                    ModelBarsCard(daily: analytics.modelDaily, tk: tk, settings: settings) {
                        model.showDashboardSettings = true
                    }
                }
                if !analytics.hourly.isEmpty {
                    HeatmapCard(hourly: analytics.hourly, tk: tk)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            adaptiveRow(paired: paired) {
                agentsCard(analytics)
                modelsCard(analytics)
            }
            SpendCard(analytics: analytics, settings: settings, tk: tk)
            if !analytics.sessionCosts.isEmpty {
                SessionCostsCard(entries: analytics.sessionCosts,
                                 glmFactor: model.glmForecast.map {
                                     $0.peakNow ? $0.factorPeak : $0.factorOffPeak
                                 } ?? nil,
                                 tk: tk, projectParts: agentProjectParts, settings: settings)
            }
        }
    }

    /// Строка из двух карточек на широком окне; на узком — те же карточки
    /// друг под другом (высота по содержимому в обоих случаях).
    @ViewBuilder
    private func adaptiveRow<Content: View>(paired: Bool,
                                            @ViewBuilder content: () -> Content) -> some View {
        if paired {
            HStack(alignment: .top, spacing: 10) { content() }
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 10) { content() }
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var forecastOff: some View {
        card {
            HStack(spacing: 8) {
                Image(systemName: "pause.circle")
                Text("GLM monitoring is off — turn it on in the provider strip")
            }
            .foregroundStyle(tk.t3)
        }
    }

    private var onboarding: some View {
        card {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "key")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tk.accent)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: Tokens.rLg).fill(tk.accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 4) {
                    Text("API key not set — add it in the limits window")
                        .font(.system(size: 13, weight: .semibold))
                    Text("The forecast engine needs a z.ai key to read GLM quotas and learn your burn rate. Quotas, peak hours and calibration start with the first snapshot.")
                        .font(.caption)
                        .foregroundStyle(tk.t2)
                    Button("Add API key") { model.showProvidersPanel = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Window cards

    private func windowCard(_ label: String, window: GLMWindowForecast?,
                            series: [GLMSeriesPoint], hours: Double,
                            sliding: Bool, now: Date,
                            extraStats: [(String, Double?)] = []) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("\(label) window")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .textCase(.uppercase)
                        .foregroundStyle(tk.t3)
                    Spacer()
                    if let window { verdictChip(window.verdict) }
                }
                if let window {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ForecastEN.headroom(window.headroomPercent))
                            .font(.system(size: 24, weight: .semibold).monospacedDigit())
                            .foregroundStyle(verdictColor(window.verdict))
                        Text("headroom to reset")
                            .font(.caption)
                            .foregroundStyle(tk.t3)
                        Spacer()
                        if let reset = window.resetAt.flatMap(msToDate),
                           let resetsIn = ForecastEN.resetsIn(reset, now: now) {
                            Text("\(resetsIn) · \(sliding ? "sliding" : "weekly reset")")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(tk.t3)
                        }
                    }
                    windowChart(label, window: window, series: series, hours: hours, now: now)
                    statsRow(window, label: label, extraStats: extraStats)
                } else {
                    Text("no data").font(.caption).foregroundStyle(tk.t3)
                }
            }
        }
    }

    private func statsRow(_ w: GLMWindowForecast, label: String,
                          extraStats: [(String, Double?)] = []) -> some View {
        HStack(spacing: 18) {
            baseStats(w, label: label)
            extraStatViews(extraStats)
            etaStat(w)
            Spacer(minLength: 0)
        }
    }

    private func baseStats(_ w: GLMWindowForecast, label: String) -> some View {
        let rateName = label == "7d" ? "rate · 24h avg" : "rate"
        let rateValue = String(format: "%.1f", w.rateCreditsPerHour) + " cr/h"
        let projected = "\(ForecastEN.credits(w.projected)) cr"
        let remaining = "\(ForecastEN.credits(w.remaining)) cr"
        let total = "\(ForecastEN.credits(w.total)) cr"
        return HStack(spacing: 18) {
            stat("projected", projected)
            stat("remaining", remaining)
            stat("total", total)
            stat(rateName, rateValue)
        }
    }

    @ViewBuilder
    private func etaStat(_ w: GLMWindowForecast) -> some View {
        if w.verdict == .overflow, let eta = w.exhaustionAt.flatMap(msToDate) {
            stat("exhaustion eta", "exhausts ~\(ForecastText.time.string(from: eta))", color: tk.err)
        }
    }

    @ViewBuilder
    private func extraStatViews(_ extra: [(String, Double?)]) -> some View {
        ForEach(Array(extra.enumerated()), id: \.offset) { _, entry in
            if let value = entry.1 {
                stat(entry.0, "\(Int((value * 100).rounded()))%")
            }
        }
    }

    /// Взвешенный по токенам cache hit квота-окна (этап 1).
    private func weightedCacheHit(_ models: [GLMModelUsage]) -> Double? {
        var cacheRead = 0.0
        var denom = 0.0
        for m in models {
            let u = m.window
            cacheRead += u.cacheRead
            denom += u.cacheRead + u.input + u.cacheCreation
        }
        return denom > 0 ? cacheRead / denom : nil
    }

    private func stat(_ name: String, _ value: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(color ?? tk.t1)
            Text(name)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .textCase(.uppercase)
                .foregroundStyle(tk.t3)
        }
    }

    private func verdictChip(_ verdict: GLMForecastVerdict) -> some View {
        let solid = verdict == .overflow
        return Text(ForecastEN.verdictChip(verdict))
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(solid ? tk.bg : verdictColor(verdict))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(solid ? tk.err : verdictColor(verdict).opacity(0.14)))
    }

    private func verdictColor(_ verdict: GLMForecastVerdict) -> Color {
        switch verdict {
        case .overflow: return tk.err
        case .tight: return tk.warn
        case .fits, .underuse: return tk.ok
        case .idle, .calibrating: return tk.t3
        }
    }

    // MARK: - Chart

    /// Cumulative credits in the window: solid fact, dashed projection to the
    /// reset, a hairline at the window total, Y hints and time labels. The
    /// projection turns err past the total, with an ETA tick at the crossing.
    private func windowChart(_ name: String, window: GLMWindowForecast,
                             series: [GLMSeriesPoint], hours: Double, now: Date) -> some View {
        let trimmed = ForecastWindow.trimmed(series, resetAt: window.resetAt,
                                             now: now, hours: hours)
        // Домен — весь период [начало, сброс], не от первой точки данных.
        let endT = Double(max(window.resetAt ?? trimmed.last?.t ?? 0, trimmed.last?.t ?? 0))
        let startT = endT - hours * 3_600_000
        var plot = trimmed
        if let first = plot.first, first.t > Int64(startT) {
            plot.insert(GLMSeriesPoint(t: Int64(startT), used: 0), at: 0)
        }
        return Group {
            if plot.count >= 2 {
                Canvas { context, size in
                    let padL: CGFloat = 6, padR: CGFloat = 48
                    let padT: CGFloat = 10, padB: CGFloat = 16
                    let x0 = padL, x1 = size.width - padR
                    let y0 = padT, y1 = size.height - padB
                    let last = plot[plot.count - 1]
                    let total = max(window.total, 1e-9)
                    // Потолок шкалы — лимит на 4/5 высоты: перелёт прогноза
                    // выше него уходит за край, важна точка исчерпания.
                    let yMax = total * 1.25

                    func x(_ t: Int64) -> CGFloat {
                        x0 + CGFloat((Double(t) - startT) / max(1, endT - startT)) * (x1 - x0)
                    }
                    func y(_ v: Double) -> CGFloat {
                        y1 - CGFloat(v / yMax) * (y1 - y0)
                    }
                    func label(_ text: String, at point: CGPoint,
                               anchor: UnitPoint = .center, color: Color) {
                        context.draw(Text(text)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(color), at: point, anchor: anchor)
                    }

                    // Y gridlines + hints.
                    for value in [0.0, total / 2, total] {
                        let line = Path { p in
                            p.move(to: CGPoint(x: x0, y: y(value)))
                            p.addLine(to: CGPoint(x: x1, y: y(value)))
                        }
                        context.stroke(line, with: .color(value == 0 ? tk.bd3 : tk.bd2), lineWidth: 1)
                        label(value == total ? "\(ForecastEN.credits(total)) cr"
                                             : ForecastEN.credits(value),
                              at: CGPoint(x: x1 + 6, y: y(value)),
                              anchor: .leading, color: tk.t3)
                    }

                    // Fact area + line.
                    var area = Path()
                    area.move(to: CGPoint(x: x(plot[0].t), y: y1))
                    for p in plot { area.addLine(to: CGPoint(x: x(p.t), y: y(p.used))) }
                    area.addLine(to: CGPoint(x: x(last.t), y: y1))
                    area.closeSubpath()
                    context.fill(area, with: .color(tk.t1.opacity(0.07)))
                    var fact = Path()
                    fact.move(to: CGPoint(x: x(plot[0].t), y: y(plot[0].used)))
                    for p in plot.dropFirst() { fact.addLine(to: CGPoint(x: x(p.t), y: y(p.used))) }
                    context.stroke(fact, with: .color(tk.t1.opacity(0.8)), lineWidth: 2)

                    // Projection: dashed from the last fact point to the reset.
                    if let reset = window.resetAt, Double(reset) > Double(last.t),
                       window.verdict != .idle, window.verdict != .calibrating {
                        // Полоса неопределённости §7d: p50–p90 темпов недели,
                        // залита от последней точки факта до сброса.
                        if let p50 = window.projectedP50, let p90 = window.projectedP90 {
                            var band = Path()
                            band.move(to: CGPoint(x: x(last.t), y: y(last.used)))
                            band.addLine(to: CGPoint(x: x(Int64(endT)), y: y(p50)))
                            band.addLine(to: CGPoint(x: x(Int64(endT)), y: y(p90)))
                            band.addLine(to: CGPoint(x: x(last.t), y: y(max(last.used, p50))))
                            band.closeSubpath()
                            context.fill(band, with: .color(tk.t1.opacity(0.08)))
                        }
                        let projected = window.projected
                        let crosses = projected > total
                        // Доля пути до пересечения — по времени от последней
                        // точки факта (плоская ставка от неё до сброса).
                        let splitT: Double = crosses
                            ? Double(last.t) + (endT - Double(last.t))
                                * (total - last.used) / max(1e-9, projected - last.used)
                            : endT
                        var head = Path()
                        head.move(to: CGPoint(x: x(last.t), y: y(last.used)))
                        head.addLine(to: CGPoint(x: x(Int64(splitT)), y: y(crosses ? total : projected)))
                        context.stroke(head, with: .color(tk.t1.opacity(0.8)),
                                       style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        if crosses {
                            var tail = Path()
                            tail.move(to: CGPoint(x: x(Int64(splitT)), y: y(total)))
                            tail.addLine(to: CGPoint(x: x(Int64(endT)), y: y(projected)))
                            context.stroke(tail, with: .color(tk.err),
                                           style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                            if let eta = window.exhaustionAt {
                                let etaDate = Date(timeIntervalSince1970: Double(eta) / 1000)
                                let tick = Path { p in
                                    p.move(to: CGPoint(x: x(eta), y: y(total) - 4))
                                    p.addLine(to: CGPoint(x: x(eta), y: y(total) + 4))
                                }
                                context.stroke(tick, with: .color(tk.err), lineWidth: 2)
                                // У недели ETA уезжает в другие дни — показываем дату;
                                // у 5h хватает времени.
                                let etaText = hours >= 24
                                    ? ForecastText.dateTime.string(from: etaDate)
                                    : ForecastText.time.string(from: etaDate)
                                label("exhausts \(etaText)",
                                      at: CGPoint(x: x(eta) - 3, y: y(total) - 9),
                                      anchor: .trailing, color: tk.err)
                            }
                        }
                        // Reset marker on the time axis.
                        label("\(ForecastText.dateTime.string(from: Date(timeIntervalSince1970: Double(reset) / 1000))) · reset",
                              at: CGPoint(x: x1, y: size.height - 5),
                              anchor: .trailing, color: tk.t3)
                    }
                    // Day ticks: локальные полуночи — видно, какие дни; для
                    // коротких окон — одна риска в середине домена.
                    let edge: Double = 2 * 3_600_000   // края заняты подписями старта/сброса
                    if hours >= 24 {
                        var tick = Calendar.current.startOfDay(
                            for: Date(timeIntervalSince1970: startT / 1000))
                        while tick.timeIntervalSince1970 * 1000 < endT {
                            let t = tick.timeIntervalSince1970 * 1000
                            if t > startT + edge, t < endT - edge {
                                let hairline = Path { p in
                                    p.move(to: CGPoint(x: x(Int64(t)), y: y0))
                                    p.addLine(to: CGPoint(x: x(Int64(t)), y: y1))
                                }
                                context.stroke(hairline, with: .color(tk.bd2.opacity(0.6)), lineWidth: 1)
                                label(ForecastText.day.string(from: tick),
                                      at: CGPoint(x: x(Int64(t)), y: size.height - 5),
                                      anchor: .center, color: tk.t3)
                            }
                            guard let next = Calendar.current.date(byAdding: .day, value: 1, to: tick)
                            else { break }
                            tick = next
                        }
                    } else {
                        let mid = (startT + endT) / 2
                        let hairline = Path { p in
                            p.move(to: CGPoint(x: x(Int64(mid)), y: y0))
                            p.addLine(to: CGPoint(x: x(Int64(mid)), y: y1))
                        }
                        context.stroke(hairline, with: .color(tk.bd2.opacity(0.6)), lineWidth: 1)
                        label(ForecastText.time.string(from: Date(timeIntervalSince1970: mid / 1000)),
                              at: CGPoint(x: x(Int64(mid)), y: size.height - 5),
                              anchor: .center, color: tk.t3)
                    }
                    // Window start on the time axis.
                    label(ForecastText.dateTime.string(from: Date(timeIntervalSince1970: startT / 1000)),
                          at: CGPoint(x: x0, y: size.height - 5),
                          anchor: .leading, color: tk.t3)
                    // Fact end dot.
                    let dot = CGRect(x: x(last.t) - 3, y: y(last.used) - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: dot), with: .color(tk.t1))
                }
                .frame(height: 168)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Cumulative credits chart, \(name) window, with projection")
            } else {
                Text("no data")
                    .font(.caption)
                    .foregroundStyle(tk.t3)
                    .frame(height: 168, alignment: .center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Agents & models
    //
    // Full-width bordered tables — sorting, filters and the hairline grid
    // live in `AgentsTable` / `ModelsTable` at the bottom of this file.
    // Here only the empty-state cards remain.

    @ViewBuilder
    private func agentsCard(_ analytics: ForecastAnalytics) -> some View {
        if !analytics.sessions.isEmpty {
            AgentsTable(rows: agentRows(analytics.sessions), tk: tk,
                        projectParts: agentProjectParts,
                        sourceColor: { settings.sourceColor(for: $0) })
        } else {
            card {
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle("Agents", hint: "analytics sessions")
                    emptyState("no active agents", "No transcript activity in the last 10 minutes.")
                }
            }
        }
    }

    /// Имя агента-пути → проект как в списке сессий (rename или последний
    /// компонент корня) + ветка worktree; тултип в таблице держит полный путь.
    private func agentProjectParts(_ raw: String) -> (project: String, branch: String?)? {
        AgentNaming.projectParts(
            raw: raw,
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            displayName: { model.displayName(forDir: $0) })
    }

    @ViewBuilder
    private func modelsCard(_ analytics: ForecastAnalytics) -> some View {
        if !analytics.models.isEmpty {
            VStack(spacing: 10) {
                ModelsTable(models: analytics.models, tk: tk)
                if !analytics.modelDaily.isEmpty {
                    tierBar(analytics.modelDaily)
                }
            }
        } else {
            card {
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle("Models", hint: "usage by model")
                    emptyState("no data", "No model usage recorded in the current window yet.")
                }
            }
        }
    }

    /// Доли токенов по классу мощности моделей за 7д (этап 1.4): топовые
    /// модели против облегчённых — куда реально уходит квота.
    private func tierBar(_ daily: [GLMDayUsage]) -> some View {
        var totals: [ModelPalette.Tier: Double] = [:]
        for day in daily {
            for (model, tokens) in day.models {
                totals[ModelPalette.tier(of: model), default: 0] += tokens
            }
        }
        let sum = totals.values.reduce(0, +)
        guard sum > 0 else { return AnyView(EmptyView()) }
        let order: [(ModelPalette.Tier, String, Double)] = [
            (.top, "flagship", totals[.top] ?? 0),
            (.mid, "mid", totals[.mid] ?? 0),
            (.light, "light", totals[.light] ?? 0),
            (.other, "other", totals[.other] ?? 0),
        ].filter { $0.2 > 0 }
        return AnyView(VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(order.enumerated()), id: \.offset) { _, entry in
                        Rectangle()
                            .fill(tierColor(entry.0))
                            .frame(width: geo.size.width * entry.2 / sum)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 5)
            HStack(spacing: 12) {
                ForEach(Array(order.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(tierColor(entry.0))
                            .frame(width: 7, height: 7)
                        Text("\(entry.1) \(Int((entry.2 / sum * 100).rounded()))%")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(tk.t2)
                    }
                }
                Spacer(minLength: 0)
            }
        })
    }

    private func tierColor(_ tier: ModelPalette.Tier) -> Color {
        switch tier {
        case .top: return tk.t1.opacity(0.9)
        case .mid: return tk.t1.opacity(0.55)
        case .light: return tk.t1.opacity(0.3)
        case .other: return tk.t3.opacity(0.3)
        }
    }


    // MARK: - Settings, empty states, sheet

    private var settingsFooter: some View {
        HStack(spacing: 12) {
            Spacer()
            if let coverage = model.glmForecast?.coverage7d {
                Text("data coverage \(Int((coverage * 100).rounded()))% · 7d")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tk.t3)
                    .help("Share of the last 7 days the monitor was actually polling — gaps (sleep, daemon off) lower the averages' trust")
            }
            if model.usageSettingsPending {
                ProgressView().controlSize(.small)
            }
            Text("snapshots arrive from the daemon · no manual refresh")
                .font(.caption.monospacedDigit())
                .foregroundStyle(tk.t3)
        }
        .padding(.top, 2)
    }

    private func sectionTitle(_ title: String, hint: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .textCase(.uppercase)
            Text("· \(hint)")
                .font(.caption)
                .foregroundStyle(tk.t3)
        }
    }

    private func emptyState(_ title: String, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12, weight: .medium, design: .monospaced))
            Text(hint).font(.caption).foregroundStyle(tk.t3)
        }
        .padding(.vertical, 10)
    }

    private func emptyCard(_ text: String) -> some View {
        card {
            Text(text).font(.caption).foregroundStyle(tk.t3)
        }
    }

    // MARK: - Shared chrome

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Tokens.rLg).fill(tk.card))
            .overlay(RoundedRectangle(cornerRadius: Tokens.rLg).stroke(tk.bd2))
    }

    // MARK: - Units

    private func msToDate(_ ms: Int64) -> Date? {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    private func secsToDate(_ secs: Int64) -> Date? {
        Date(timeIntervalSince1970: Double(secs))
    }
}

// MARK: - Data tables
//
// Bordered grid: hairline column separators, row dividers, a header band
// with click-to-sort columns. Agents add an all/active filter, models a
// window/last-hour scope switch. Agent names collapse $HOME to "~",
// truncate from the middle (the branch/uuid tail stays visible) and dim
// the shared `.worktrees/` root; the full path lives in the tooltip.

/// A table row: hover tint + bottom hairline except the last row.
private struct TableRow<Content: View>: View {
    let tk: Tokens
    var divider: Bool
    @ViewBuilder var content: Content
    @State private var hovered = false

    var body: some View {
        content
            .background(Rectangle().fill(hovered ? tk.cardHover : .clear))
            .overlay(alignment: .bottom) {
                if divider { Rectangle().fill(tk.bd2).frame(height: 1) }
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

private extension View {
    /// Cell box: inset + column frame (nil width = the flexible leading
    /// column) + hairline on the leading column boundary.
    func tableCell(_ tk: Tokens, width: CGFloat? = nil,
                   align: Alignment = .trailing, divider: Bool = false) -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: width, alignment: align)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: align)
            .overlay(alignment: .leading) {
                if divider { Rectangle().fill(tk.bd2).frame(width: 1) }
            }
    }
}

private func tableTitleBar<Trailing: View>(_ title: String, hint: String, tk: Tokens,
                                           @ViewBuilder trailing: () -> Trailing) -> some View {
    HStack(spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .textCase(.uppercase)
            Text("· \(hint)")
                .font(.caption)
                .foregroundStyle(tk.t3)
        }
        Spacer(minLength: 12)
        trailing()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
}

/// A small control chip: filters (all/active) and the models scope switch.
private func tableChip(_ title: String, selected: Bool, tk: Tokens,
                       action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .textCase(.uppercase)
            .foregroundStyle(selected ? tk.t1 : tk.t3)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? tk.surf3 : .clear))
            .overlay(Capsule().stroke(tk.bd2))
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}

private func tableEmpty(_ title: String, _ hint: String, tk: Tokens) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.system(size: 12, weight: .medium, design: .monospaced))
        Text(hint).font(.caption).foregroundStyle(tk.t3)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
}

private struct AgentsTable: View {
    let rows: [AgentRow]
    let tk: Tokens
    /// Путь агента → (имя проекта, ветка); nil — имя не путь, показ как был.
    let projectParts: (String) -> (project: String, branch: String?)?
    /// Цвет имени по источнику (Claude Code / Codex) — из настроек дашборда.
    let sourceColor: (ForecastUsageSource) -> Color

    /// Ширины колонок — общие для шапки и строк; заголовок не должен переноситься.
    private enum Col {
        static let active: CGFloat = 76
        static let ext: CGFloat = 56
        static let tokens: CGFloat = 86
        static let credits: CGFloat = 88
        static let cache: CGFloat = 64
        static let share: CGFloat = 104
        static let budget: CGFloat = 84
        static let ctx: CGFloat = 100
    }

    private enum Sort {
        case name, active, ext, tokens, credits, cache, share, budget, ctx
    }

    @State private var sort: Sort = .credits
    @State private var ascending = false
    @State private var activeOnly = true

    private var visible: [AgentRow] {
        let pool = activeOnly ? rows.filter(\.active) : rows
        return pool.sorted { a, b in
            if sort == .name {
                let order = ForecastEN.tildePath(a.name)
                    .localizedStandardCompare(ForecastEN.tildePath(b.name))
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
            let va = numeric(a), vb = numeric(b)
            return ascending ? va < vb : va > vb
        }
    }

    /// Несколько сессий одного проекта дают одинаковые имена — различаем их
    /// коротким id, иначе строки неотличимы.
    private var nameCounts: [String: Int] {
        Dictionary(grouping: rows, by: \.name).mapValues(\.count)
    }

    private func numeric(_ a: AgentRow) -> Double {
        switch sort {
        case .name: return 0
        case .active: return a.active ? 1 : 0
        case .ext: return a.external ? 1 : 0
        case .tokens: return a.tokensPerHour
        case .credits: return a.creditsPerHour ?? -1
        case .cache: return a.cacheHit ?? -1
        case .share: return a.sharePercent
        case .budget: return a.budgetMinutes ?? -1
        case .ctx: return a.contextTokens ?? -1
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tableTitleBar("Agents", hint: "analytics sessions", tk: tk) {
                tableChip("all \(rows.count)", selected: !activeOnly, tk: tk) {
                    activeOnly = false
                }
                tableChip("active \(rows.filter(\.active).count)", selected: activeOnly, tk: tk) {
                    activeOnly = true
                }
            }
            header
            if visible.isEmpty {
                tableEmpty("no active agents",
                           "No transcript activity in the last 10 minutes.", tk: tk)
            } else {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, agent in
                    TableRow(tk: tk, divider: index < visible.count - 1) {
                        rowCells(agent)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(tk.card)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.rLg))
        .overlay(RoundedRectangle(cornerRadius: Tokens.rLg).stroke(tk.bd2))
    }

    private var header: some View {
        HStack(spacing: 0) {
            sortHead("name", .name, width: nil, align: .leading)
            sortHead("active", .active, width: Col.active, align: .center)
            sortHead("ext", .ext, width: Col.ext, align: .center)
            sortHead("tokens/h", .tokens, width: Col.tokens)
            sortHead("credits/h", .credits, width: Col.credits)
            sortHead("cache", .cache, width: Col.cache)
            sortHead("share", .share, width: Col.share)
            sortHead("budget", .budget, width: Col.budget)
            sortHead("ctx", .ctx, width: Col.ctx)
        }
        .background(tk.surf3)
        .overlay(alignment: .bottom) { Rectangle().fill(tk.bd3).frame(height: 1) }
    }

    @ViewBuilder
    private func sortHead(_ title: String, _ key: Sort, width: CGFloat?,
                          align: Alignment = .trailing) -> some View {
        Button {
            if sort == key { ascending.toggle() }
            else { sort = key; ascending = (key == .name) }
        } label: {
            // Шеврон — в оверлее у края, не в потоке: невидимый сортировочный
            // индикатор не должен сдвигать заголовок относительно значений.
            Group {
                if align == .leading {
                    HStack(spacing: 3) {
                        Text(title)
                        Image(systemName: ascending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(sort == key ? tk.accent : .clear)
                    }
                    .padding(.horizontal, 10)
                } else {
                    Text(title)
                        .padding(.leading, 10)
                        .padding(.trailing, 16)
                        .overlay(alignment: .trailing) {
                            Image(systemName: ascending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(sort == key ? tk.accent : .clear)
                                .offset(x: -5)
                        }
                }
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .textCase(.uppercase)
            .foregroundStyle(sort == key ? tk.t1 : tk.t3)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)   // заголовок не переносится
            .padding(.vertical, 6)
            .frame(width: width, alignment: align)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: align)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            if key != .name { Rectangle().fill(tk.bd2).frame(width: 1) }
        }
        .help(key == .budget
              ? "Sort by budget — time until this agent alone burns through the 5h window's remaining credits at its own rate; a large value means the window resets first"
              : "Sort by \(title)")
    }

    private func rowCells(_ a: AgentRow) -> some View {
        HStack(spacing: 0) {
            nameCell(a)
                .tableCell(tk, width: nil, align: .leading)
            activeCell(a)
                .tableCell(tk, width: Col.active, align: .center, divider: true)
            externalCell(a)
                .tableCell(tk, width: Col.ext, align: .center, divider: true)
            Text(ForecastWindow.compactTokens(a.tokensPerHour))
                .tableCell(tk, width: Col.tokens, divider: true)
            Text(a.creditsPerHour.map { String(format: "%.2f", $0) } ?? "—")
                .tableCell(tk, width: Col.credits, divider: true)
            Text(a.cacheHit.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .tableCell(tk, width: Col.cache, divider: true)
                .help("Cache hit — share of context billed at cache price (last 15 min)")
            shareCell(a)
                .tableCell(tk, width: Col.share, divider: true)
            Text(a.budgetMinutes.map { ForecastEN.duration(minutes: $0) } ?? "—")
                .tableCell(tk, width: Col.budget, divider: true)
            ctxCell(a)
                .tableCell(tk, width: Col.ctx, divider: true)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(tk.t2)
    }

    /// «45.2k ·+3.1k» — размер промпта последнего хода и рост за ход
    /// (отрицательный = контекст сброшен).
    @ViewBuilder
    private func ctxCell(_ a: AgentRow) -> some View {
        if let tokens = a.contextTokens {
            let delta = a.contextDeltaPerTurn.map {
                ($0 >= 0 ? "+" : "−") + ForecastWindow.compactTokens(abs($0))
            }
            Text(delta.map { "\(ForecastWindow.compactTokens(tokens)) \($0)" }
                ?? ForecastWindow.compactTokens(tokens))
                .help("Context of the last turn and its growth per turn")
        } else {
            Text("—")
        }
    }

    private func nameCell(_ a: AgentRow) -> some View {
        // Источник — цветом имени (настраивается в настройках дашборда),
        // без отдельного бейджа; внешность — отдельная колонка ext.
        let color = sourceColor(a.source)
        return HStack(spacing: 6) {
            AgentIcon(agent: agentIconCommand(for: a.source), tk: tk)
            if let parts = projectParts(a.name) {
                // Имя проекта как в списке сессий; ветка worktree приглушена.
                Text(parts.project)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let branch = parts.branch, !branch.isEmpty {
                    Text(branch)
                        .foregroundStyle(tk.t3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text(ForecastEN.tildePath(a.name))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if (nameCounts[a.name] ?? 0) > 1 {
                tag("#\(a.id.prefix(8))")
            }
        }
        .help(a.name)
    }

    /// Внешняя сессия (не из реестра Covey) — отдельной колонкой.
    private func externalCell(_ a: AgentRow) -> some View {
        Text(a.external ? "yes" : "—")
            .foregroundStyle(a.external ? tk.t2 : tk.t3)
    }

    /// Rows share the worktree root, so everything up to and including
    /// `.worktrees/` is dimmed — the branch and agent id carry the signal.
    private func dimmedPath(_ path: String) -> Text {
        guard let range = path.range(of: "/.worktrees/") else {
            return Text(path).foregroundStyle(tk.t1)
        }
        var root = AttributedString(String(path[..<range.upperBound]))
        root.foregroundColor = tk.t3
        var tail = AttributedString(String(path[range.upperBound...]))
        tail.foregroundColor = tk.t1
        return Text(root + tail)
    }

    private func tag(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
            .textCase(.uppercase)
            .foregroundStyle(tk.t3)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tk.surf3))
            .overlay(Capsule().stroke(tk.bd2))
    }

    private func activeCell(_ a: AgentRow) -> some View {
        HStack(spacing: 4) {
            Circle().fill(a.active ? tk.ok : tk.t3).frame(width: 5, height: 5)
            Text(a.active ? "yes" : "—")
                .foregroundStyle(a.active ? tk.t1 : tk.t3)
        }
    }

    private func shareCell(_ a: AgentRow) -> some View {
        HStack(spacing: 6) {
            Text("\(Int(a.sharePercent.rounded()))%")
            ZStack(alignment: .leading) {
                Capsule().fill(tk.surf3)
                Capsule().fill(tk.t1.opacity(0.75))
                    .frame(width: 36 * min(max(a.sharePercent, 0), 100) / 100)
            }
            .frame(width: 36, height: 4)
        }
    }
}

private struct ModelsTable: View {
    let models: [GLMModelUsage]
    let tk: Tokens

    private enum Scope: CaseIterable {
        case window, lastHour

        var title: String { self == .window ? "window" : "last hour" }
    }

    private enum Sort {
        case model, input, output, cacheCreation, cacheRead, hit
    }

    @State private var scope: Scope = .window
    @State private var sort: Sort = .input
    @State private var ascending = false

    private var rows: [GLMModelUsage] {
        models.sorted { a, b in
            if sort == .model {
                let order = a.model.localizedStandardCompare(b.model)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
            let va = numeric(a), vb = numeric(b)
            return ascending ? va < vb : va > vb
        }
    }

    private func usage(_ m: GLMModelUsage) -> GLMTokenUsage {
        scope == .window ? m.window : m.lastHour
    }

    private func numeric(_ m: GLMModelUsage) -> Double {
        let u = usage(m)
        switch sort {
        case .model: return 0
        case .input: return u.input
        case .output: return u.output
        case .cacheCreation: return u.cacheCreation
        case .cacheRead: return u.cacheRead
        case .hit: return u.cacheHit ?? -1
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tableTitleBar("Models", hint: "glm usage", tk: tk) {
                ForEach(Scope.allCases, id: \.self) { s in
                    tableChip(s.title, selected: scope == s, tk: tk) { scope = s }
                }
            }
            header
            ForEach(Array(rows.enumerated()), id: \.element.model) { index, m in
                TableRow(tk: tk, divider: index < rows.count - 1) {
                    rowCells(m)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(tk.card)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.rLg))
        .overlay(RoundedRectangle(cornerRadius: Tokens.rLg).stroke(tk.bd2))
    }

    private var header: some View {
        HStack(spacing: 0) {
            sortHead("model", .model, width: nil, align: .leading)
            sortHead("in", .input, width: 92)
            sortHead("out", .output, width: 92)
            sortHead("cache+", .cacheCreation, width: 112)
            sortHead("cache", .cacheRead, width: 112)
            sortHead("hit", .hit, width: 56)
        }
        .background(tk.surf3)
        .overlay(alignment: .bottom) { Rectangle().fill(tk.bd3).frame(height: 1) }
    }

    @ViewBuilder
    private func sortHead(_ title: String, _ key: Sort, width: CGFloat?,
                          align: Alignment = .trailing) -> some View {
        Button {
            if sort == key { ascending.toggle() }
            else { sort = key; ascending = (key == .model) }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: ascending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(sort == key ? tk.accent : .clear)
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .textCase(.uppercase)
            .foregroundStyle(sort == key ? tk.t1 : tk.t3)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: width, alignment: align)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: align)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            if key != .model { Rectangle().fill(tk.bd2).frame(width: 1) }
        }
        .help("Sort by \(title)")
    }

    private func rowCells(_ m: GLMModelUsage) -> some View {
        let u = usage(m)
        return HStack(spacing: 0) {
            Text(m.model)
                .lineLimit(1)
                .foregroundStyle(tk.t1)
                .tableCell(tk, width: nil, align: .leading)
            Text(ForecastWindow.compactTokens(u.input))
                .tableCell(tk, width: 92, divider: true)
            Text(ForecastWindow.compactTokens(u.output))
                .tableCell(tk, width: 92, divider: true)
            Text(ForecastWindow.compactTokens(u.cacheCreation))
                .tableCell(tk, width: 112, divider: true)
            Text(ForecastWindow.compactTokens(u.cacheRead))
                .tableCell(tk, width: 112, divider: true)
            Text(u.cacheHit.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .tableCell(tk, width: 56, divider: true)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(tk.t2)
    }
}

extension ForecastEN {
    /// "1h 24m" from minutes — the agents-table budget column.
    static func duration(minutes: Double) -> String {
        let m = Int(minutes.rounded())
        let hours = m / 60
        return hours > 0 ? "\(hours)h \(m % 60)m" : "\(m)m"
    }
}
