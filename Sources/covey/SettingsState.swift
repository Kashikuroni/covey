import Foundation

struct SettingsValues: Equatable {
    var theme: Theme
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
    case vimMode
    case providerKey
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
    var selectedRow: SettingsRow = .theme

    init(values: SettingsValues) {
        self.values = values
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
