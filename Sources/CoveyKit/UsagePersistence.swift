
extension PersistedUsageWindow {
    public init(_ w: UsageWindow) {
        self.init(utilization: w.utilization, resetUnix: w.resetUnix)
    }
    public var live: UsageWindow { UsageWindow(utilization: utilization, resetUnix: resetUnix) }
}

extension PersistedUsage {
    public init(_ usage: Usage) {
        self.init(fiveHour: usage.fiveHour.map(PersistedUsageWindow.init),
                  sevenDay: usage.sevenDay.map(PersistedUsageWindow.init),
                  sevenDaySonnet: usage.sevenDaySonnet.map(PersistedUsageWindow.init))
    }
    public var live: Usage {
        Usage(fiveHour: fiveHour?.live, sevenDay: sevenDay?.live, sevenDaySonnet: sevenDaySonnet?.live)
    }
}

extension PersistedCodexUsage {
    public init(_ snapshot: CodexRateLimitsSnapshot) {
        let legacy = snapshot.buckets["codex"]
            ?? snapshot.buckets.sorted { $0.key < $1.key }.first?.value
        self.init(
            primaryLabel: legacy?.primary?.label,
            primaryDurationMinutes: legacy?.primary?.durationMinutes,
            primary: legacy?.primary.map { PersistedUsageWindow($0.window) },
            secondaryLabel: legacy?.secondary?.label,
            secondaryDurationMinutes: legacy?.secondary?.durationMinutes,
            secondary: legacy?.secondary.map { PersistedUsageWindow($0.window) },
            buckets: snapshot.buckets.mapValues { bucket in
                PersistedCodexRateLimitBucket(
                    name: bucket.name,
                    primaryLabel: bucket.primary?.label,
                    primaryDurationMinutes: bucket.primary?.durationMinutes,
                    primary: bucket.primary.map { PersistedUsageWindow($0.window) },
                    secondaryLabel: bucket.secondary?.label,
                    secondaryDurationMinutes: bucket.secondary?.durationMinutes,
                    secondary: bucket.secondary.map { PersistedUsageWindow($0.window) })
            })
    }
    public var live: CodexRateLimitsSnapshot {
        if let buckets, !buckets.isEmpty {
            let liveBuckets = buckets.reduce(into: [String: CodexRateLimitBucket]()) {
                result, entry in
                let (id, bucket) = entry
                result[id] = CodexRateLimitBucket(
                    id: id,
                    name: bucket.name,
                    primary: Self.liveWindow(label: bucket.primaryLabel,
                                             durationMinutes: bucket.primaryDurationMinutes,
                                             window: bucket.primary),
                    secondary: Self.liveWindow(label: bucket.secondaryLabel,
                                               durationMinutes: bucket.secondaryDurationMinutes,
                                               window: bucket.secondary))
            }
            return CodexRateLimitsSnapshot(buckets: liveBuckets)
        }
        let primaryWindow: LabeledWindow? = {
            guard let label = primaryLabel, let window = primary else { return nil }
            return LabeledWindow(label: label,
                                 durationMinutes: primaryDurationMinutes,
                                 window: window.live)
        }()
        let secondaryWindow: LabeledWindow? = {
            guard let label = secondaryLabel, let window = secondary else { return nil }
            return LabeledWindow(label: label,
                                 durationMinutes: secondaryDurationMinutes,
                                 window: window.live)
        }()
        return CodexRateLimitsSnapshot(primary: primaryWindow, secondary: secondaryWindow)
    }

    private static func liveWindow(label: String?, durationMinutes: Int?,
                                   window: PersistedUsageWindow?) -> LabeledWindow? {
        guard let label, let window else { return nil }
        return LabeledWindow(label: label, durationMinutes: durationMinutes,
                             window: window.live)
    }
}
