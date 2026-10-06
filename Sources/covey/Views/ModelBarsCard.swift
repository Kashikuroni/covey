import SwiftUI
import CoveyKit

/// Столбчатый график «токены по моделям» (§7d): столбец = день (неделя/месяц)
/// или агрегат (неделя для квартала, месяц для года), стек = модели, цвет по
/// провайдеру (Claude — оранжевые тона, GPT — бирюзовые, GLM — розовые),
/// оттенок ярче у более мощной модели. Сетка Y — токены, подписи X — «дней
/// назад» (today, 1d, …). Цвета настраиваются шестерёнкой (UserDefaults).
struct ModelBarsCard: View {
    let daily: [GLMDayUsage]
    let tk: Tokens

    enum Range: CaseIterable {
        case week, month, quarter, year

        var days: Int {
            switch self {
            case .week: return 7
            case .month: return 30
            case .quarter: return 91
            case .year: return 365
            }
        }

        var title: String {
            switch self {
            case .week: return "week"
            case .month: return "month"
            case .quarter: return "quarter"
            case .year: return "year"
            }
        }

        /// Столбец диапазона: неделя/месяц — день, квартал — неделя, год — месяц.
        var binDays: Int {
            switch self {
            case .week, .month: return 1
            case .quarter: return 7
            case .year: return 30
            }
        }
    }

    /// Один столбец: подпись-дата начала столбца + токены по моделям.
    struct Bin: Equatable {
        var label: String
        var models: [String: Double]
        var usage: [String: GLMTokenUsage]?
    }

    /// Подпись столбца: «Tue 10.06» — день недели + дата, всегда EN.
    static let barLabel: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE MM.dd"
        return f
    }()

    /// Чистый биннинг (для тестов): дневные вёдра → столбцы диапазона,
    /// слева старые; подпись — дата начала столбца.
    static func bins(from daily: [GLMDayUsage], range: Range, now: Date) -> [Bin] {
        let cal = Calendar.current
        let byDay = Dictionary(uniqueKeysWithValues: daily.map { ($0.t, ($0.models, $0.usage)) })
        var out: [Bin] = []
        switch range {
        case .week, .month:
            for offset in stride(from: range.days - 1, through: 0, by: -1) {
                let day = cal.startOfDay(
                    for: now.addingTimeInterval(TimeInterval(-offset) * 86_400))
                let key = Int64(day.timeIntervalSince1970 * 1000)
                let entry = byDay[key] ?? ([:], nil)
                out.append(Bin(label: barLabel.string(from: day),
                               models: entry.0, usage: entry.1))
            }
        case .quarter, .year:
            // Агрегаты календарными шагами: неделя (квартал) / месяц (год).
            let unit: Calendar.Component = range == .quarter ? .weekOfMonth : .month
            var starts: [Date] = [cal.startOfDay(for: now)]
            while let prev = cal.date(byAdding: unit, value: -1, to: starts.last!),
                  now.timeIntervalSince(prev) <= Double(range.days + range.binDays) * 86_400 {
                starts.append(prev)
            }
            for start in starts.reversed() {
                let end = cal.date(byAdding: unit, value: 1, to: start) ?? now
                var models: [String: Double] = [:]
                var usage: [String: GLMTokenUsage] = [:]
                for (day, values) in byDay where day >= Int64(start.timeIntervalSince1970 * 1000)
                    && day < Int64(min(end, now).timeIntervalSince1970 * 1000) {
                    for (m, v) in values.0 { models[m, default: 0] += v }
                    for (m, u) in values.1 ?? [:] {
                        var acc = usage[m] ?? GLMTokenUsage()
                        acc.input += u.input; acc.output += u.output
                        acc.cacheCreation += u.cacheCreation; acc.cacheRead += u.cacheRead
                        usage[m] = acc
                    }
                }
                out.append(Bin(label: barLabel.string(from: start), models: models,
                               usage: usage.isEmpty ? nil : usage))
            }
        }
        return out
    }

    let settings: DashboardSettings
    let onOpenSettings: () -> Void

    @State private var range: Range = .week
    @State private var hover: CGPoint?

    private var bins: [Bin] { ModelBarsCard.bins(from: daily, range: range, now: Date()) }

    /// Покопонентные итоги диапазона: модель → биллинг-компоненты.
    private var rangeUsage: [String: GLMTokenUsage] {
        var out: [String: GLMTokenUsage] = [:]
        for day in daily {
            for (m, u) in day.usage ?? [:] {
                var acc = out[m] ?? GLMTokenUsage()
                acc.input += u.input; acc.output += u.output
                acc.cacheCreation += u.cacheCreation; acc.cacheRead += u.cacheRead
                out[m] = acc
            }
        }
        return out
    }

    /// $ за весь диапазон — если у каждой модели задан прайс в реестре.
    private var rangeCost: Double? {
        let usage = rangeUsage
        guard !usage.isEmpty else { return nil }
        var sum = 0.0
        for (m, u) in usage {
            guard let c = settings.cost(model: m, usage: u) else { return nil }
            sum += c
        }
        return sum
    }

    private var models: [String] {
        let all = Set(daily.flatMap(\.models.keys))
        return all.sorted {
            let pa = ModelPalette.provider(of: $0), pb = ModelPalette.provider(of: $0)
            if pa != pb { return providerOrder(pa) < providerOrder(pb) }
            let ra = ModelPalette.powerRank($0), rb = ModelPalette.powerRank($1)
            return ra == rb ? $0 < $1 : ra < rb
        }
    }

    private func providerOrder(_ p: ModelPalette.Provider) -> Int {
        switch p {
        case .claude: return 0
        case .gpt: return 1
        case .glm: return 2
        case .other: return 3
        }
    }

    private func color(_ model: String) -> Color {
        settings.color(model: model, within: models)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("tokens by model")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .textCase(.uppercase)
                if let rangeCost {
                    Text("· ~$" + String(format: "%.2f", rangeCost))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tk.t2)
                        .help("Estimated cost of the visible range at the prices from chart settings")
                }
                Spacer()
                ForEach(Range.allCases, id: \.title) { r in
                    Button {
                        range = r
                    } label: {
                        Text(r.title)
                            .font(.system(size: 9, weight: range == r ? .semibold : .regular,
                                           design: .monospaced))
                            .foregroundStyle(range == r ? tk.t1 : tk.t3)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(range == r ? tk.surf3 : Color.clear))
                            .overlay(Capsule().stroke(tk.bd2))
                    }
                    .buttonStyle(.plain)
                }
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundStyle(tk.t3)
                }
                .buttonStyle(.plain)
                .help("Dashboard settings — model colors and prices")
            }
            bars
            legend
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: Tokens.rLg).fill(tk.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.rLg).stroke(tk.bd2))
    }

    private var bars: some View {
        Canvas { context, size in
            let plotBins = bins
            guard !plotBins.isEmpty else { return }
            let maxTotal = max(plotBins.map { $0.models.values.reduce(0, +) }.max() ?? 0, 1e-9)
            let padL: CGFloat = 6, padR: CGFloat = 56
            let padT: CGFloat = 6, padB: CGFloat = 16
            let plotH = size.height - padB - padT
            let x0 = padL, x1 = size.width - padR
            let slot = (x1 - x0) / CGFloat(plotBins.count)
            let barW = min(30, slot * 0.55)

            // Сетка Y: 0, половина, максимум — подписи в токенах справа.
            func y(_ v: Double) -> CGFloat {
                size.height - padB - CGFloat(v / maxTotal) * plotH
            }
            for value in [0.0, maxTotal / 2, maxTotal] {
                let line = Path { p in
                    p.move(to: CGPoint(x: x0, y: y(value)))
                    p.addLine(to: CGPoint(x: x1, y: y(value)))
                }
                context.stroke(line, with: .color(value == 0 ? tk.bd3 : tk.bd2), lineWidth: 1)
                context.draw(Text(ForecastWindow.compactTokens(value))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(tk.t3),
                    at: CGPoint(x: x1 + 6, y: y(value)), anchor: .leading)
            }

            // Подпись X не на каждый столбец: до ~8 на всю ширину.
            let stride = max(1, plotBins.count / 8)
            for (i, bin) in plotBins.enumerated() {
                var top = size.height - padB
                let cx = x0 + slot * (CGFloat(i) + 0.5)
                for model in models {
                    guard let v = bin.models[model], v > 0 else { continue }
                    let h = CGFloat(v / maxTotal) * plotH
                    let rect = CGRect(x: cx - barW / 2, y: top - h, width: barW, height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2),
                                 with: .color(color(model)))
                    top -= h
                }
                if i % stride == 0 || i == plotBins.count - 1 {
                    context.draw(Text(bin.label)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(tk.t3),
                        at: CGPoint(x: cx, y: size.height - 6), anchor: .center)
                }
            }

            // Hover-тултип столбца: дата + модели с токенами и $.
            if let hover,
               hover.x >= x0, hover.x < x1, hover.y < size.height - padB {
                let index = Int((hover.x - x0) / slot)
                let bin = plotBins[min(max(index, 0), plotBins.count - 1)]
                var lines = [bin.label]
                let total = bin.models.values.reduce(0, +)
                lines.append("total \(ForecastWindow.compactTokens(total)) tok")
                for model in models.sorted(by: {
                    (bin.models[$0] ?? 0) > (bin.models[$1] ?? 0)
                }) {
                    guard let v = bin.models[model], v > 0 else { continue }
                    var line = "\(model)  \(ForecastWindow.compactTokens(v))"
                    let u = bin.usage?[model] ?? GLMTokenUsage()
                    if let c = settings.cost(model: model, usage: u) {
                        line += String(format: "  $%.2f", c)
                    }
                    lines.append(line)
                }
                drawTooltip(context: context, lines: lines,
                            around: CGPoint(x: hover.x, y: 8), size: size)
            }
        }
        .frame(height: 150)
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let point) = phase { hover = point }
            else { hover = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily token usage stacked by model")
    }

    /// Общий тултип-бокс над графиком: рамка + строки моно-шрифтом.
    private func drawTooltip(context: GraphicsContext, lines: [String],
                             around point: CGPoint, size: CGSize) {
        let rowH: CGFloat = 13
        let boxW = CGFloat(170)
        let boxH = CGFloat(lines.count) * rowH + 8
        let bx = min(max(point.x - boxW / 2, 4), size.width - boxW - 4)
        let by = point.y
        let box = Path(roundedRect: CGRect(x: bx, y: by, width: boxW, height: boxH),
                       cornerRadius: 4)
        context.fill(box, with: .color(tk.surface.opacity(0.97)))
        context.stroke(box, with: .color(tk.bd2), lineWidth: 1)
        for (i, line) in lines.enumerated() {
            context.draw(Text(line)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundColor(tk.t1),
                at: CGPoint(x: bx + 8, y: by + 6 + CGFloat(i) * rowH),
                anchor: .leading)
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(models, id: \.self) { model in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(model))
                        .frame(width: 8, height: 8)
                    Text(model)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(tk.t2)
                }
                .help("\(model) — \(ForecastWindow.compactTokens(daily.reduce(0) { $0 + ($1.models[model] ?? 0) })) tokens / 7d")
            }
            Spacer(minLength: 0)
        }
    }

}
