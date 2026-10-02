import Foundation

/// Расписание повышенного расхода z.ai: пн–пт 14:00–18:00 UTC+8 — пик
/// (полный множитель), остальное время, включая выходные, — офф-пик
/// (premium ≈ 0.5×). Чистые функции: движок проверяет расписание, а
/// калибровка подтверждает фактический множитель цифрами.
public enum PeakSchedule {
    private static let zone = TimeZone(secondsFromGMT: 8 * 3600)!

    public static func isPeak(at date: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let hour = cal.component(.hour, from: date)
        let weekday = cal.component(.weekday, from: date)  // 1=вс … 7=сб
        return (2...6).contains(weekday) && (14..<18).contains(hour)
    }

    /// [from, to) → сегменты одного режима; длительности в сумме = to−from.
    public static func segments(from: Date, to: Date) -> [(peak: Bool, duration: TimeInterval)] {
        guard from < to else { return [] }
        var result: [(Bool, TimeInterval)] = []
        var cursor = from
        while cursor < to {
            let peak = isPeak(at: cursor)
            let flip = nextFlip(after: cursor)
            let end = min(flip, to)
            result.append((peak, end.timeIntervalSince(cursor)))
            cursor = end
        }
        return result.map { (peak: $0.0, duration: $0.1) }
    }

    /// Ближайшая граница режима строго после date: половины часов 14:00/18:00
    /// UTC+8, пропуская выходные. Граница, на которую попал сам date, не считается.
    public static func nextFlip(after date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        var day = cal.startOfDay(for: date)
        // До 7 дней вперёд: любая неделя содержит обе границы по будням.
        for _ in 0...8 {
            let weekday = cal.component(.weekday, from: day)
            if (2...6).contains(weekday) {
                for hour in [14, 18] {
                    guard let edge = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day),
                          edge > date else { continue }
                    return edge
                }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return date.addingTimeInterval(7 * 86400)  // недостижимо при верном календаре
    }
}
