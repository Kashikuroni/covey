import SwiftUI
import CoveyKit

/// Линейный график расходов в $ по моделям за период (§spend): день —
/// часовые точки, неделя и дальше — дневные. Линии — кумулятивные, цвет
/// модели из реестра; тотал за период крупно в шапке. $ — по компонентам
/// биллинга × прайс; модели без прайса в графике не участвуют.
struct SpendCard: View {
    let analytics: ForecastAnalytics
    let settings: DashboardSettings
    let tk: Tokens

    enum Range: CaseIterable {
        case day, week, month, quarter, year
        var title: String { "\(self)".lowercased() }
        var days: Int {
            switch self {
            case .day: return 1
            case .week: return 7
            case .month: return 30
            case .quarter: return 91
            case .year: return 365
            }
        }
    }

    /// Один интервал серии: $ по моделям за интервал (не кумулятивно).
    struct Point: Equatable {
        var t: Int64
        var byModel: [String: Double]
    }

    /// Чистый биннинг (для тестов): почасовая гранулярность для коротких
    /// окон (день), дневная — для длинных; окно `window` перекрывает
    /// пресет range. $ по модели = прайс × компоненты интервала; модели
    /// без прайса пропускаются.
    static func series(hourly: [GLMHourUsage], daily: [GLMDayUsage],
                       range: Range,
                       window: ClosedRange<Date>? = nil,
                       cost: (String, GLMTokenUsage) -> Double?,
                       now: Date) -> (points: [Point], byModel: [String: Double],
                                      total: Double?) {
        let cal = Calendar.current
        let winStart = window?.lowerBound
            ?? cal.startOfDay(for: now.addingTimeInterval(TimeInterval(-range.days + 1) * 86_400))
        let winEnd = window?.upperBound ?? now
        let spanHours = winEnd.timeIntervalSince(winStart) / 3600
        let hourlyGranularity = spanHours <= 48
        var raw: [(t: Int64, usage: [String: GLMTokenUsage])] = []
        if hourlyGranularity {
            raw = hourly
                .filter {
                    let d = Date(timeIntervalSince1970: Double($0.t) / 1000)
                    return d >= winStart && d <= winEnd
                }
                .map { ($0.t, $0.usage) }
        } else {
            raw = daily
                .filter {
                    let d = Date(timeIntervalSince1970: Double($0.t) / 1000)
                    return d >= winStart && d <= winEnd
                }
                .map { ($0.t, $0.usage ?? [:]) }
        }
        var points: [Point] = []
        var byModel: [String: Double] = [:]
        for (t, usage) in raw.sorted(by: { $0.t < $1.t }) {
            var dollars: [String: Double] = [:]
            for (model, u) in usage {
                if let c = cost(model, u), c > 0 {
                    dollars[model] = c
                    byModel[model, default: 0] += c
                }
            }
            points.append(Point(t: t, byModel: dollars))
        }
        let total = byModel.values.reduce(0, +)
        return (points, byModel, byModel.isEmpty ? nil : total)
    }

    @State private var range: Range = .week
    @State private var hover: CGPoint?
    @State private var customFrom: Date?
    @State private var customTo: Date?
    @State private var showWindowPicker = false
    @State private var pickerFrom = Date()
    @State private var pickerTo = Date()

    private var customWindow: ClosedRange<Date>? {
        guard let from = customFrom, let to = customTo, from <= to else { return nil }
        return from...min(to, Date())
    }

    private var series: (points: [Point], byModel: [String: Double], total: Double?) {
        SpendCard.series(hourly: analytics.modelHourly,
                         daily: analytics.modelDaily,
                         range: range,
                         window: customWindow,
                         cost: { settings.cost(model: $0, usage: $1) },
                         now: Date())
    }

    private var models: [String] {
        series.byModel.keys.sorted {
            (series.byModel[$0] ?? 0) > (series.byModel[$1] ?? 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("$ spend")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .textCase(.uppercase)
                if let total = series.total {
                    Text("· " + String(format: "$%.2f", total))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tk.t1)
                    Text("· \(range.title)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tk.t3)
                } else {
                    Text("· set model prices in settings")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tk.t3)
                }
                Spacer()
                ForEach(Range.allCases, id: \.title) { r in
                    Button {
                        range = r
                        customFrom = nil
                        customTo = nil
                    } label: {
                        Text(r.title)
                            .font(.system(size: 9,
                                           weight: range == r && customWindow == nil ? .semibold : .regular,
                                           design: .monospaced))
                            .foregroundStyle(range == r && customWindow == nil ? tk.t1 : tk.t3)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(range == r && customWindow == nil ? tk.surf3 : Color.clear))
                            .overlay(Capsule().stroke(tk.bd2))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    pickerFrom = customFrom ?? Calendar.current.startOfDay(
                        for: Date().addingTimeInterval(-7 * 86_400))
                    pickerTo = customTo ?? Date()
                    showWindowPicker = true
                } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 10))
                        .foregroundStyle(customWindow != nil ? tk.t1 : tk.t3)
                }
                .buttonStyle(.plain)
                .help("Pick a custom date range")
            }
            if series.total == nil {
                Text("No priced spend in this range — set $ prices via the gear in the top bar")
                    .font(.caption)
                    .foregroundStyle(tk.t3)
                    .padding(.vertical, 10)
            } else {
                chart
                legend
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Tokens.rLg).fill(tk.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.rLg).stroke(tk.bd2))
        .sheet(isPresented: $showWindowPicker) { windowPickerSheet }
    }

    private var windowPickerSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom range")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .textCase(.uppercase)
            DatePicker("From", selection: $pickerFrom, displayedComponents: .date)
                .datePickerStyle(.compact)
            DatePicker("To", selection: $pickerTo, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.compact)
            Text("Up to 48 hours uses hourly points; longer ranges use days")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(tk.t3)
            HStack {
                if customWindow != nil {
                    Button("Reset to presets") {
                        customFrom = nil
                        customTo = nil
                        showWindowPicker = false
                    }
                    .buttonStyle(AyuButton(tk: tk, prominent: false))
                }
                Spacer()
                Button("Cancel") { showWindowPicker = false }
                    .buttonStyle(AyuButton(tk: tk, prominent: false))
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    customFrom = Calendar.current.startOfDay(for: pickerFrom)
                    customTo = Calendar.current.startOfDay(for: pickerTo)
                        .addingTimeInterval(86_399)
                    showWindowPicker = false
                }
                .buttonStyle(AyuButton(tk: tk, prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(pickerFrom > pickerTo)
            }
        }
        .padding(16)
        .frame(width: 320)
        .foregroundStyle(tk.t1)
        .presentationBackground(tk.surface)
    }

    private var chart: some View {
        Canvas { context, size in
            let points = series.points
            guard points.count >= 1, !models.isEmpty else { return }
            let padL: CGFloat = 6, padR: CGFloat = 56
            let padT: CGFloat = 8, padB: CGFloat = 16
            let x0 = padL, x1 = size.width - padR
            let y0 = padT, y1 = size.height - padB
            // Домен — весь выбранный период: пустые дни честно лежат
            // нулём, короткая история не растягивается на весь диапазон.
            let cal = Calendar.current
            let windowStart = customWindow?.lowerBound
                ?? cal.startOfDay(for: Date().addingTimeInterval(
                    TimeInterval(-range.days + 1) * 86_400))
            let windowEnd = customWindow?.upperBound ?? Date()
            let startT = windowStart.timeIntervalSince1970 * 1000
            let endT = max(windowEnd.timeIntervalSince1970 * 1000, startT + 1)
            let spanT = endT - startT

            // Кумулятивные серии: значения по точкам + нулевой старт окна.
            var cum: [String: Double] = [:]
            var cumValues: [String: [Double]] = [:]
            var cumTimes: [Double] = [startT]   // виртуальный ноль в начале окна
            for m in models { cumValues[m, default: []].append(0) }
            for p in points {
                cumTimes.append(Double(p.t))
                for m in models {
                    cum[m] = (cum[m] ?? 0) + (p.byModel[m] ?? 0)
                    cumValues[m, default: []].append(cum[m] ?? 0)
                }
            }
            let maxY = max((models.map { cum[$0] ?? 0 }.max() ?? 0) * 1.06, 1e-9)
            func y(_ v: Double) -> CGFloat {
                y1 - CGFloat(v / maxY) * (y1 - y0)
            }
            func x(_ t: Double) -> CGFloat {
                x0 + CGFloat((t - startT) / spanT) * (x1 - x0)
            }
            var cumSeries: [String: [CGPoint]] = [:]
            for m in models {
                cumSeries[m] = (0..<cumTimes.count).map {
                    CGPoint(x: x(cumTimes[$0]), y: y(cumValues[m]?[$0] ?? 0))
                }
            }

            // Сетка Y: 0 / половина / максимум — подписи $ справа.
            for value in [0.0, maxY / 2, maxY] {
                let line = Path { p in
                    p.move(to: CGPoint(x: x0, y: y(value)))
                    p.addLine(to: CGPoint(x: x1, y: y(value)))
                }
                context.stroke(line, with: .color(value == 0 ? tk.bd3 : tk.bd2), lineWidth: 1)
                context.draw(Text(String(format: "$%.2f", value))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(tk.t3),
                    at: CGPoint(x: x1 + 6, y: y(value)), anchor: .leading)
            }

            for m in models {
                guard let line = cumSeries[m], line.count >= 2 else { continue }
                var path = Path()
                path.move(to: line[0])
                for pt in line.dropFirst() { path.addLine(to: pt) }
                context.stroke(path, with: .color(color(m)), lineWidth: 1.8)
            }
            // Конец окна — вертикальная риска (граница периода).
            let edge = Path { p in
                p.move(to: CGPoint(x: x1, y: y0))
                p.addLine(to: CGPoint(x: x1, y: y1))
            }
            context.stroke(edge, with: .color(tk.bd3), lineWidth: 1)

            // Ось X: короткое окно — часы, иначе — даты по домену окна.
            let hourlyGranularity = spanT <= 48 * 3_600_000
            let marks: [Double] = {
                var out: [Double] = []
                if hourlyGranularity {
                    for h in stride(from: startT, through: endT, by: 6 * 3_600_000) {
                        out.append(h)
                    }
                } else {
                    for d in stride(from: startT, through: endT, by: 86_400_000) {
                        out.append(d)
                    }
                }
                return out
            }()
            let strideMark = max(1, marks.count / 8)
            for (i, t) in marks.enumerated() where i % strideMark == 0 || i == marks.count - 1 {
                let date = Date(timeIntervalSince1970: t / 1000)
                let label = hourlyGranularity
                    ? String(format: "%02d:00", Calendar.current.component(.hour, from: date))
                    : ModelBarsCard.barLabel.string(from: date)
                context.draw(Text(label)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(tk.t3),
                    at: CGPoint(x: x(t), y: size.height - 5),
                    anchor: .center)
            }

            // Hover-тултип интервала: $ на модель в этой точке.
            if let hover,
               hover.x >= x0, hover.x < x1, hover.y < y1 {
                let index = Int((hover.x - x0) / (x1 - x0) * CGFloat(points.count - 1))
                let p = points[min(max(index, 0), points.count - 1)]
                var lines = [range == .day
                    ? String(format: "%02d:00",
                             Calendar.current.component(.hour,
                                from: Date(timeIntervalSince1970: Double(p.t) / 1000)))
                    : ModelBarsCard.barLabel.string(
                        from: Date(timeIntervalSince1970: Double(p.t) / 1000))]
                for m in models.sorted(by: { (p.byModel[$0] ?? 0) > (p.byModel[$1] ?? 0) }) {
                    guard let v = p.byModel[m] else { continue }
                    lines.append(String(format: "%@  $%.2f", m, v))
                }
                drawTooltip(context: context, lines: lines,
                            around: CGPoint(x: hover.x, y: 10), size: size)
            }
        }
        .frame(height: 150)
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let point) = phase { hover = point }
            else { hover = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cumulative dollar spend by model")
    }

    private func color(_ model: String) -> Color {
        settings.color(model: model, within: Array(series.byModel.keys))
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(models, id: \.self) { m in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(m))
                        .frame(width: 8, height: 8)
                    Text("\(m) $\(String(format: "%.2f", series.byModel[m] ?? 0))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(tk.t2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func drawTooltip(context: GraphicsContext, lines: [String],
                             around point: CGPoint, size: CGSize) {
        let rowH: CGFloat = 13
        let boxW = CGFloat(170)
        let boxH = CGFloat(lines.count) * rowH + 8
        let bx = min(max(point.x - boxW / 2, 4), size.width - boxW - 4)
        let box = Path(roundedRect: CGRect(x: bx, y: point.y, width: boxW, height: boxH),
                       cornerRadius: 4)
        context.fill(box, with: .color(tk.surface.opacity(0.97)))
        context.stroke(box, with: .color(tk.bd2), lineWidth: 1)
        for (i, line) in lines.enumerated() {
            context.draw(Text(line)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundColor(tk.t1),
                at: CGPoint(x: bx + 8, y: point.y + 6 + CGFloat(i) * rowH),
                anchor: .leading)
        }
    }
}
