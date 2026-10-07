import Foundation

/// Прогноз одного rate-limit окна Codex (этап 2): расход по наблюдаемым
/// дельтам сэмплов, проекция к resetAt, вердикт и неопределённость.
/// Все таймстемпы — Unix milliseconds; upstream `resetsAt` (секунды)
/// конвертируются ровно один раз на входе в пайплайн.
public enum CodexForecastVerdict: String, Codable, Equatable, Sendable {
    case fits, tight, overflow, underuse, idle, calibrating
}

/// Слот bucket-а: `primary` — короткое окно, `secondary` — длинное.
public enum CodexForecastWindowKey: String, Codable, Equatable, Sendable {
    case primary, secondary
}

public struct CodexWindowForecast: Codable, Equatable, Sendable, Comparable {
    public var bucketID: String
    public var windowKey: CodexForecastWindowKey
    public var label: String
    public var verdict: CodexForecastVerdict
    public var usedPercent: Double
    public var projectedPercent: Double
    public var projectedP50: Double?
    public var projectedP90: Double?
    public var headroomPercent: Double
    public var resetAt: Int64?          // Unix ms
    public var exhaustionAt: Int64?     // Unix ms
    public var ratePercentPerHour: Double
    public var sampleCount: Int
    public var stale: Bool

    /// Канонический порядок: по upstream bucketID, затем primary перед
    /// secondary — единый для стора, IPC и UI.
    public static func < (lhs: CodexWindowForecast, rhs: CodexWindowForecast) -> Bool {
        if lhs.bucketID != rhs.bucketID { return lhs.bucketID < rhs.bucketID }
        guard lhs.windowKey != rhs.windowKey else { return false }
        return lhs.windowKey == .primary
    }

    public init(bucketID: String, windowKey: CodexForecastWindowKey,
                label: String, verdict: CodexForecastVerdict,
                usedPercent: Double, projectedPercent: Double,
                projectedP50: Double?, projectedP90: Double?,
                headroomPercent: Double, resetAt: Int64?, exhaustionAt: Int64?,
                ratePercentPerHour: Double, sampleCount: Int, stale: Bool) {
        self.bucketID = bucketID; self.windowKey = windowKey; self.label = label
        self.verdict = verdict; self.usedPercent = usedPercent
        self.projectedPercent = projectedPercent
        self.projectedP50 = projectedP50; self.projectedP90 = projectedP90
        self.headroomPercent = headroomPercent
        self.resetAt = resetAt; self.exhaustionAt = exhaustionAt
        self.ratePercentPerHour = ratePercentPerHour
        self.sampleCount = sampleCount; self.stale = stale
    }
}

/// Полный прогноз Codex-квоты: по одному окну на каждый видимый слот
/// каждого видимого bucket-а, отсортировано по bucketID, затем primary
/// перед secondary.
public struct CodexForecast: Codable, Equatable, Sendable {
    public var windows: [CodexWindowForecast]
    public var updatedAt: Int64         // Unix ms

    public init(windows: [CodexWindowForecast] = [], updatedAt: Int64) {
        self.windows = windows
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case windows, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Отсутствующий ключ означает пустой набор, а не повреждение.
        windows = try c.decodeIfPresent([CodexWindowForecast].self, forKey: .windows) ?? []
        updatedAt = try c.decode(Int64.self, forKey: .updatedAt)
    }
}
