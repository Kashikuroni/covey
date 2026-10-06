import Foundation
import CoveyKit

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
    var cwds: [String: String] = [:]      // slug каталога проекта → реальный cwd транскрипта
    var gaps: [[Int64]] = []              // паузы опроса [start, end] ms — не нулевой расход
    var modelDays: [GLMDayUsage]?         // дневные токены по моделям, до года (§график)
    var sessionLedger: [String: SessionCostRecord]?   // живые сессии (этап 0)
    var sessionArchive: [String: SessionCostRecord]?  // финализированные, cap 500
    var hourTotals: [GLMSeriesPoint]?     // токены по часам, 90 дней (этап 0)
    var hourUsage: [GLMHourUsage]?        // час × модель × компоненты, 8 дней (§spend)
    var lastContext: [String: LastContextRecord]?     // контекст сессий, 14 дней
    var factors = PersistedFactors()
}

public final class QuotaSampleStore {
    private var file = ForecastFile()
    private let path: String?

    /// Бэкап прошлого хорошего состояния (ротация при каждой записи).
    static func backupPath(_ path: String) -> String { path + ".bak" }

    public init(path: String?) {
        self.path = path
        guard let path else { return }
        // Битый/старый файл — не ошибка запуска: главный не декодируется —
        // откатываемся на бэкап; и он не годится — начинаем с пустого стейта.
        for candidate in [path, Self.backupPath(path)] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: candidate)) else { continue }
            if let decoded = try? JSONDecoder().decode(ForecastFile.self, from: data) {
                file = decoded
                break
            }
        }
    }

    public func append(_ sample: QuotaSample) {
        let minute = sample.t - sample.t % 60_000
        var merged = sample
        merged.t = minute
        if let i = file.minute.lastIndex(where: { $0.t == minute }) {
            file.minute[i] = merged            // тот же опрос/ретрай — перезаписать
        } else {
            // Пауза опроса (сон демона/Mac) — не нулевой расход: дельты через
            // неё считать нельзя, окна — вычитать её время.
            if let last = file.minute.last, minute - last.t > Self.gapThresholdMs {
                file.gaps.append([last.t, minute])
            }
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
        file.gaps.removeAll { $0[1] < weekAgo }
    }

    /// Пауза длиннее двух пропущенных опросов (опрос ~1/мин) — разрыв.
    private static let gapThresholdMs: Int64 = 3 * 60_000

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
    public var cwds: [String: String] { file.cwds }
    public func setCWD(_ slug: String, cwd: String) { file.cwds[slug] = cwd }
    public var gaps: [[Int64]] { file.gaps }
    /// Те же разрывы интервалами — движку удобнее фильтровать дельты.
    public var gapRanges: [Range<Double>] {
        file.gaps.compactMap { $0.count == 2 ? Double($0[0])..<Double($0[1]) : nil }
    }

    /// Дневные токены по моделям (агрегатор хранит вёдра всего 8 дней —
    /// историю дальше держит эта серия). Дни перезаписываются по ключу-полуночи.
    public var modelDays: [GLMDayUsage] { file.modelDays ?? [] }

    public func upsertModelDays(_ days: [GLMDayUsage], now: Date) {
        var byDay = Dictionary(uniqueKeysWithValues: modelDays.map { ($0.t, $0) })
        for d in days { byDay[d.t] = d }   // свежий снапшот дня перезаписывает
        let cutoff = Int64(now.addingTimeInterval(-365 * 86_400).timeIntervalSince1970 * 1000)
        file.modelDays = byDay.filter { $0.key >= cutoff }
            .sorted { $0.key < $1.key }.map { $0.value }
    }

    // MARK: Этап 0 — накопление истории (roadmap docs/forecast_metrics_roadmap.md)

    /// Живые сессии: тоталы монотонны (max по моделям), firstSeen/lastSeen —
    /// расширение диапазона. Сессия молчит дольше archiveAfter и не приехала
    /// в снапшоте — финализируется в архив (cap archiveCap по свежести).
    public var sessionLedger: [String: SessionCostRecord] { file.sessionLedger ?? [:] }
    public var sessionArchive: [String: SessionCostRecord] { file.sessionArchive ?? [:] }

    public func upsertSessions(_ incoming: [String: SessionCostRecord], now: Date,
                               archiveAfter: TimeInterval = 3 * 24 * 3600,
                               archiveCap: Int = 500) {
        var live = sessionLedger
        for (uuid, rec) in incoming {
            var merged = live[uuid] ?? rec
            merged.firstSeen = min(merged.firstSeen, rec.firstSeen)
            merged.lastSeen = max(merged.lastSeen, rec.lastSeen)
            for (m, v) in rec.byModel {
                merged.byModel[m] = max(merged.byModel[m] ?? 0, v)
            }
            // Компоненты биллинга мержатся монотонно по каждой.
            if rec.usage != nil {
                var usage = merged.usage ?? [:]
                for (m, u) in rec.usage! {
                    let old = usage[m] ?? GLMTokenUsage()
                    usage[m] = GLMTokenUsage(
                        input: max(old.input, u.input),
                        output: max(old.output, u.output),
                        cacheCreation: max(old.cacheCreation, u.cacheCreation),
                        cacheRead: max(old.cacheRead, u.cacheRead))
                }
                merged.usage = usage
            }
            merged.external = rec.external
            if rec.cwd != nil { merged.cwd = rec.cwd }
            live[uuid] = merged
        }
        let cutoff = Int64(now.addingTimeInterval(-archiveAfter).timeIntervalSince1970 * 1000)
        var archive = sessionArchive
        for (uuid, rec) in live where rec.lastSeen < cutoff {
            archive[uuid] = rec
            live[uuid] = nil
        }
        if archive.count > archiveCap {
            let drop = archive.sorted { $0.value.lastSeen > $1.value.lastSeen }
                .suffix(archive.count - archiveCap)
            for (uuid, _) in drop { archive[uuid] = nil }
        }
        file.sessionLedger = live
        file.sessionArchive = archive
    }

    /// Токены по часам (t = начало часа): текущие часы из вёдер перезаписывают
    /// накопленное, история — 90 дней.
    public var hourTotals: [GLMSeriesPoint] { file.hourTotals ?? [] }

    public func upsertHourTotals(_ points: [GLMSeriesPoint], now: Date) {
        var byHour = Dictionary(uniqueKeysWithValues: hourTotals.map { ($0.t, $0.used) })
        for p in points { byHour[p.t] = p.used }
        let cutoff = Int64(now.addingTimeInterval(-90 * 86_400).timeIntervalSince1970 * 1000)
        file.hourTotals = byHour.filter { $0.key >= cutoff }
            .sorted { $0.key < $1.key }
            .map { GLMSeriesPoint(t: $0.key, used: $0.value) }
    }

    /// Час × модель × компоненты (§spend): свежий снапшот часа перезаписывает,
    /// история — 8 дней (вёдра живут столько же).
    public var hourUsage: [GLMHourUsage] { file.hourUsage ?? [] }

    public func upsertHourUsage(_ hours: [GLMHourUsage], now: Date) {
        var byHour = Dictionary(uniqueKeysWithValues: hourUsage.map { ($0.t, $0) })
        for h in hours { byHour[h.t] = h }
        let cutoff = Int64(now.addingTimeInterval(-8 * 86_400).timeIntervalSince1970 * 1000)
        file.hourUsage = byHour.filter { $0.key >= cutoff }
            .sorted { $0.key < $1.key }.map { $0.value }
    }

    /// Текущий контекст сессий: свежая порция заменяет запись, молчаливые
    /// сессии держатся 14 дней.
    public var lastContext: [String: LastContextRecord] { file.lastContext ?? [:] }

    public func upsertLastContext(_ incoming: [String: LastContextRecord],
                                  now: Date = Date()) {
        var ctx = lastContext
        for (uuid, rec) in incoming { ctx[uuid] = rec }
        let cutoff = Int64(now.addingTimeInterval(-14 * 86_400).timeIntervalSince1970 * 1000)
        file.lastContext = ctx.filter { $0.value.t >= cutoff }
    }
    public var factors: PersistedFactors { file.factors }
    public func setFactors(_ value: PersistedFactors) { file.factors = value }

    public func save() throws {
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Ротация: в .bak попадает только декодируемое состояние, испорченный
        // главный хороший бэкап не затирает. Ошибка копии записи не мешает.
        if let data = try? Data(contentsOf: url),
           (try? JSONDecoder().decode(ForecastFile.self, from: data)) != nil {
            try? FileManager.default.copyItem(atPath: path, toPath: Self.backupPath(path))
        }
        try JSONEncoder().encode(file).write(to: url, options: .atomic)
    }
}
