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
        self.init(primaryLabel: snapshot.primary?.label,
                  primary: snapshot.primary.map { PersistedUsageWindow($0.window) },
                  secondaryLabel: snapshot.secondary?.label,
                  secondary: snapshot.secondary.map { PersistedUsageWindow($0.window) })
    }
    var live: CodexRateLimitsSnapshot {
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
}
