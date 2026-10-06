import SwiftUI
import CoveyKit

/// Тепловая карта потребления час×день (этап 2): колонка — локальный день,
/// строка — час суток (0 снизу, 23 сверху, время растёт вверх), сетка —
/// линии каждые 6 часов и границы дней; тултип по наведению. Диапазоны —
/// неделя/месяц/квартал из 90-дневной серии почасовок.
struct HeatmapCard: View {
    let hourly: [GLMSeriesPoint]
    let tk: Tokens

    enum Span: CaseIterable {
        case week, month, quarter
        var days: Int { self == .week ? 7 : self == .month ? 30 : 90 }
        var title: String { self == .week ? "week" : self == .month ? "month" : "quarter" }
    }

    @State private var span: Span = .week
    @State private var hover: CGPoint?

    private var cal: Calendar { Calendar.current }

    /// (день, [час → токены]) за диапазон, старые слева.
    private var columns: [(day: Date, byHour: [Int: Double])] {
        let now = Date()
        let hoursByDay = Dictionary(grouping: hourly) { p -> Date in
            cal.startOfDay(for: Date(timeIntervalSince1970: Double(p.t) / 1000))
        }
        return (0..<span.days).compactMap { ago in
            guard let day = cal.date(byAdding: .day, value: -ago, to: cal.startOfDay(for: now)) else {
                return nil
            }
            var byHour: [Int: Double] = [:]
            for p in hoursByDay[day] ?? [] {
                let h = cal.component(.hour, from: Date(timeIntervalSince1970: Double(p.t) / 1000))
                byHour[h, default: 0] += p.used
            }
            return (day, byHour)
        }
        .sorted { $0.day < $1.day }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("burn heatmap")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .textCase(.uppercase)
                Text("· hour × day").foregroundStyle(tk.t3)
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
            grid
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: Tokens.rLg).fill(tk.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.rLg).stroke(tk.bd2))
    }

    /// Тултип-бокс (тот же вид, что у столбцов Tokens by Model).
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

    private var grid: some View {
        Canvas { context, size in
            let cols = columns
            guard !cols.isEmpty else { return }
            let padL: CGFloat = 26, padR: CGFloat = 6, padT: CGFloat = 6, padB: CGFloat = 16
            let plotW = size.width - padL - padR
            let plotH = size.height - padT - padB
            let cw = plotW / CGFloat(cols.count)
            let ch = plotH / 24
            let maxHour = max(cols.flatMap { $0.byHour.values }.max() ?? 0, 1e-9)
            // Время растёт вверх: час 0 — нижняя строка.
            func cellY(_ hour: Int) -> CGFloat {
                padT + CGFloat(23 - hour) * ch
            }

            // Сетка: горизонтальные линии каждые 6 часов + правая граница 24.
            for hour in stride(from: 0, through: 24, by: 6) {
                let y = padT + CGFloat(24 - hour) * ch
                let line = Path { p in
                    p.move(to: CGPoint(x: padL, y: y))
                    p.addLine(to: CGPoint(x: padL + plotW, y: y))
                }
                context.stroke(line, with: .color(tk.bd2), lineWidth: 0.5)
                context.draw(Text(String(format: "%02d", hour))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(tk.t3),
                    at: CGPoint(x: padL - 4, y: y), anchor: .trailing)
            }
            // Вертикальные границы дней (кроме плотного quarter — каждая 7-я).
            let dayStride = max(1, cols.count / 14)
            for i in 0...cols.count where i % dayStride == 0 || i == cols.count {
                let x = padL + CGFloat(i) * cw
                let line = Path { p in
                    p.move(to: CGPoint(x: x, y: padT))
                    p.addLine(to: CGPoint(x: x, y: padT + plotH))
                }
                context.stroke(line, with: .color(tk.bd2.opacity(0.6)), lineWidth: 0.5)
            }

            for (i, col) in cols.enumerated() {
                for hour in 0..<24 {
                    let v = col.byHour[hour] ?? 0
                    let intensity = v > 0 ? 0.15 + 0.85 * (v / maxHour) : 0
                    let rect = CGRect(x: padL + CGFloat(i) * cw + 0.75,
                                      y: cellY(hour) + 0.75,
                                      width: max(1, cw - 1.5), height: max(1, ch - 1.5))
                    context.fill(Path(roundedRect: rect, cornerRadius: 1),
                                 with: .color(tk.accent.opacity(intensity)))
                }
                let stride = max(1, cols.count / 8)
                if i % stride == 0 || i == cols.count - 1 {
                    let label = i == cols.count - 1
                        ? "today" : ModelBarsCard.barLabel.string(from: col.day)
                    context.draw(Text(label)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(tk.t3),
                        at: CGPoint(x: padL + CGFloat(i) * cw + cw / 2, y: size.height - 5),
                        anchor: .center)
                }
            }

            // Hover-тултип ячейки: «Tue 10.06 · 14:00 — 2.1M tok».
            if let hover,
               hover.x >= padL, hover.x < padL + plotW,
               hover.y >= padT, hover.y < padT + plotH {
                let index = Int((hover.x - padL) / cw)
                let hour = 23 - Int((hover.y - padT) / ch)
                let col = cols[min(max(index, 0), cols.count - 1)]
                let value = col.byHour[min(max(hour, 0), 23)] ?? 0
                let lines = [
                    "\(ModelBarsCard.barLabel.string(from: col.day)) · \(String(format: "%02d:00", max(hour, 0)))",
                    "\(ForecastWindow.compactTokens(value)) tok",
                ]
                drawTooltip(context: context, lines: lines,
                            around: CGPoint(x: hover.x, y: 10), size: size)
            }
        }
        .frame(height: 160)
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let point) = phase { hover = point }
            else { hover = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Token burn heatmap by hour and day")
    }
}
