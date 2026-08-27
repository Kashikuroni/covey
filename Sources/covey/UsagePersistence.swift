import CoveyKit

extension PersistedUsageWindow {
    init(_ w: UsageWindow) {
        self.init(utilization: w.utilization, resetUnix: w.resetUnix)
    }
    var live: UsageWindow { UsageWindow(utilization: utilization, resetUnix: resetUnix) }
}

extension PersistedUsage {
    init(_ usage: Usage) {
        self.init(fiveHour: usage.fiveHour.map(PersistedUsageWindow.init),
                  sevenDay: usage.sevenDay.map(PersistedUsageWindow.init),
                  sevenDaySonnet: usage.sevenDaySonnet.map(PersistedUsageWindow.init))
    }
    var live: Usage {
        Usage(fiveHour: fiveHour?.live, sevenDay: sevenDay?.live, sevenDaySonnet: sevenDaySonnet?.live)
    }
}

extension PersistedCodexUsage {
    init(_ snapshot: CodexRateLimitsSnapshot) {
        let legacy = snapshot.buckets["codex"]
            ?? snapshot.buckets.sorted { $0.key < $1.key }.first?.value
        self.init(
            primaryLabel: legacy?.primary?.label,
            primary: legacy?.primary.map { PersistedUsageWindow($0.window) },
            secondaryLabel: legacy?.secondary?.label,
            secondary: legacy?.secondary.map { PersistedUsageWindow($0.window) },
            buckets: snapshot.buckets.mapValues { bucket in
                PersistedCodexRateLimitBucket(
                    name: bucket.name,
                    primaryLabel: bucket.primary?.label,
                    primary: bucket.primary.map { PersistedUsageWindow($0.window) },
                    secondaryLabel: bucket.secondary?.label,
                    secondary: bucket.secondary.map { PersistedUsageWindow($0.window) })
            })
    }
    var live: CodexRateLimitsSnapshot {
        if let buckets, !buckets.isEmpty {
            let liveBuckets = buckets.reduce(into: [String: CodexRateLimitBucket]()) {
                result, entry in
                let (id, bucket) = entry
                result[id] = CodexRateLimitBucket(
                    id: id,
                    name: bucket.name,
                    primary: Self.liveWindow(label: bucket.primaryLabel, window: bucket.primary),
                    secondary: Self.liveWindow(label: bucket.secondaryLabel,
                                               window: bucket.secondary))
            }
            return CodexRateLimitsSnapshot(buckets: liveBuckets)
        }
        let primaryWindow: LabeledWindow? = {
            guard let label = primaryLabel, let window = primary else { return nil }
            return LabeledWindow(label: label, window: window.live)
        }()
        let secondaryWindow: LabeledWindow? = {
            guard let label = secondaryLabel, let window = secondary else { return nil }
            return LabeledWindow(label: label, window: window.live)
        }()
        return CodexRateLimitsSnapshot(primary: primaryWindow, secondary: secondaryWindow)
    }

    private static func liveWindow(label: String?, window: PersistedUsageWindow?) -> LabeledWindow? {
        guard let label, let window else { return nil }
        return LabeledWindow(label: label, window: window.live)
    }
}
