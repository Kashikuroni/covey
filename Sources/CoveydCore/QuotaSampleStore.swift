import Foundation

/// Один опрос квоты z.ai: накопительный расход в кредитах на момент t.
/// `used` кумулятивен внутри окна — фолды серий хранят ПОСЛЕДНИЙ сэмпл ведра.
public struct QuotaSample: Codable, Equatable, Sendable {
    public var t: Int64
    public var fiveUsed: Double
    public var fiveReset: Int64
    public var weekUsed: Double
    public var weekReset: Int64
    public init(t: Int64, fiveUsed: Double, fiveReset: Int64, weekUsed: Double, weekReset: Int64) {
        self.t = t; self.fiveUsed = fiveUsed; self.fiveReset = fiveReset
        self.weekUsed = weekUsed; self.weekReset = weekReset
    }
}

/// Токены одной (минута × сессия × модель × sidechain)-ячейки — форма
/// хранения агрегатора (Task 4) и единица калибровки (Task 6).
public struct TokenBucket: Codable, Equatable, Sendable {
    public var m: Int64
    public var s: String
    public var model: String
    public var x: Bool
    public var input, output, cacheCreation, cacheRead: Double
    public init(m: Int64, s: String, model: String, x: Bool,
                input: Double, output: Double, cacheCreation: Double, cacheRead: Double) {
        self.m = m; self.s = s; self.model = model; self.x = x
        self.input = input; self.output = output
        self.cacheCreation = cacheCreation; self.cacheRead = cacheRead
    }
    public var total: Double { input + output + cacheCreation + cacheRead }
}

public struct PersistedFactors: Codable, Equatable, Sendable {
    public var peak: Double?
    public var offPeak: Double?
    public var peakAt: Int64?
    public var offPeakAt: Int64?
    public var recentPeak: [Double] = []
    public var recentOffPeak: [Double] = []
    public init() {}
}

/// Весь прогноз-стейт демона в одном атомарном JSON рядом с usage.json.
/// Битый файл = пустое состояние: прогноз начнёт собираться заново, лимиты
/// это не затрагивает (они в usage.json).
struct ForecastFile: Codable {
    var minute: [QuotaSample] = []
    var fiveMin: [QuotaSample] = []
    var buckets: [TokenBucket] = []
    var offsets: [String: UInt64] = [:]
    var factors = PersistedFactors()
}

public final class QuotaSampleStore {
    private var file = ForecastFile()
    private let path: String?

    public init(path: String?) {
        self.path = path
        guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        // Битый/старый файл — не ошибка запуска: начинаем с пустого стейта.
        if let decoded = try? JSONDecoder().decode(ForecastFile.self, from: data) { file = decoded }
    }

    public func append(_ sample: QuotaSample) {
        let minute = sample.t - sample.t % 60_000
        var merged = sample
        merged.t = minute
        if let i = file.minute.lastIndex(where: { $0.t == minute }) {
            file.minute[i] = merged            // тот же опрос/ретрай — перезаписать
        } else {
            file.minute.append(merged)
            file.minute.sort { $0.t < $1.t }
        }
        let twoHoursAgo = sample.t - 2 * 3600_000
        let old = file.minute.filter { $0.t < twoHoursAgo }
        if !old.isEmpty {
            file.minute.removeAll { $0.t < twoHoursAgo }
            for bucket in Dictionary(grouping: old, by: { $0.t - $0.t % 300_000 }) {
                let last = bucket.value.max { $0.t < $1.t }!
                upsert5Min(last)
            }
        }
        let weekAgo = sample.t - 7 * 24 * 3600_000
        file.fiveMin.removeAll { $0.t < weekAgo }
    }

    private func upsert5Min(_ sample: QuotaSample) {
        let bucket = sample.t - sample.t % 300_000
        if let i = file.fiveMin.firstIndex(where: { $0.t == bucket }) {
            file.fiveMin[i] = sample
        } else {
            file.fiveMin.append(sample)
            file.fiveMin.sort { $0.t < $1.t }
        }
    }

    public func minuteSeries(now: Date, minutes: Int) -> [QuotaSample] {
        let cutoff = Int64(now.timeIntervalSince1970 * 1000) - Int64(minutes) * 60_000
        return file.minute.filter { $0.t >= cutoff }
    }

    public func weekSeries(now: Date, days: Int) -> [QuotaSample] {
        let cutoff = Int64(now.timeIntervalSince1970 * 1000) - Int64(days) * 24 * 3600_000
        return (file.fiveMin + file.minute).filter { $0.t >= cutoff }.sorted { $0.t < $1.t }
    }

    public var buckets: [TokenBucket] { file.buckets }
    public func setBuckets(_ value: [TokenBucket]) { file.buckets = value }
    public var offsets: [String: UInt64] { file.offsets }
    public func setOffset(_ path: String, _ value: UInt64) { file.offsets[path] = value }
    public var factors: PersistedFactors { file.factors }
    public func setFactors(_ value: PersistedFactors) { file.factors = value }

    public func save() throws {
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(file).write(to: url, options: .atomic)
    }
}
