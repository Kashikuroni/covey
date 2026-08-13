import Foundation

struct SettingsValues: Equatable {
    var theme: Theme
    var providerId: String = "anthropic"
    var vimMode: Bool
    var showSessions: Bool
    var showHeader: Bool
    var showFooter: Bool
    var usagePlacement: UsagePlacement
    var claudeUsageEnabled: Bool
    var codexUsageEnabled: Bool
    var glmUsageEnabled: Bool
}

enum SettingsRow: Int, CaseIterable, Equatable {
    case theme
    case provider
    case providerKey
    case vimMode
    case showSessions
    case showHeader
    case showFooter
    case usagePlacement
    case claudeUsage
    case codexUsage
    case glmUsage
}

enum SettingsAction: Equatable { case cancel, save }

enum SettingsKey: Equatable {
    case moveDown, moveUp, decrease, increase, activate, cancel
}

func settingsKey(for character: Character) -> SettingsKey? {
    switch latinize(character) {
    case "j": return .moveDown
    case "k": return .moveUp
    case "h": return .decrease
    case "l": return .increase
    default: return nil
    }
}

struct SettingsDraft: Equatable {
    var values: SettingsValues
    /// Provider ids the `.provider` row cycles through (from `ProviderRegistry`).
    var providerIds: [String] = ["anthropic", "glm"]
    var selectedRow: SettingsRow = .theme

    init(values: SettingsValues, providerIds: [String] = ["anthropic", "glm"]) {
        self.values = values
        self.providerIds = providerIds.isEmpty ? ["anthropic"] : providerIds
    }

    mutating func handle(_ key: SettingsKey) -> SettingsAction? {
        switch key {
        case .moveDown:
            move(1)
        case .moveUp:
            move(-1)
        case .decrease:
            adjust(increasing: false)
        case .increase:
            adjust(increasing: true)
        case .activate:
            return .save
        case .cancel:
            return .cancel
        }
        return nil
    }

    private mutating func move(_ delta: Int) {
        let last = SettingsRow.allCases.count - 1
        let next = min(last, max(0, selectedRow.rawValue + delta))
        selectedRow = SettingsRow(rawValue: next) ?? .theme
    }

    private mutating func adjust(increasing: Bool) {
        switch selectedRow {
        case .theme:
            if increasing { values.theme = .light }
            else { values.theme = .dark }
        case .provider:
            // Cycle through the registry's provider ids, wrapping at both ends.
            let i = providerIds.firstIndex(of: values.providerId) ?? 0
            let next = (i + (increasing ? 1 : -1) + providerIds.count) % providerIds.count
            values.providerId = providerIds[next]
        case .providerKey:
            break   // activated via .activate in the sheet (opens the key prompt)
        case .vimMode:
            values.vimMode = increasing
        case .showSessions:
            values.showSessions = increasing
        case .showHeader:
            values.showHeader = increasing
        case .showFooter:
            values.showFooter = increasing
        case .usagePlacement:
            switch (values.usagePlacement, increasing) {
            case (.left, true): values.usagePlacement = .center
            case (.center, true): values.usagePlacement = .right
            case (.right, false): values.usagePlacement = .center
            case (.center, false): values.usagePlacement = .left
            default: break
            }
        case .claudeUsage:
            values.claudeUsageEnabled = increasing
        case .codexUsage:
            values.codexUsageEnabled = increasing
        case .glmUsage:
            values.glmUsageEnabled = increasing
        }
    }
}
