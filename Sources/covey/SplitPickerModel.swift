import Foundation
import CoveyKit

/// Чистая логика модалки сплита (spec «Модалка выбора»): пункт «Терминал»
/// первым, ниже — сессии проекта в порядке `orderedSessions()`, исключая
/// участвующие в дереве и невидимые (`companionOf != nil`).
struct SplitPickerItem: Equatable, Identifiable {
    enum Kind: Equatable { case terminal, session(String) }
    let kind: Kind
    var label: String
    var id: String {
        switch kind {
        case .terminal: return "terminal"
        case .session(let name): return "session:\(name)"
        }
    }
}

enum SplitPicker {
    static func items(projectSessions: [Session], tree: PaneNode?,
                      companionShell: String?, companionRoot: String?,
                      projectRoot: String?) -> [SplitPickerItem] {
        var items = [SplitPickerItem(kind: .terminal, label: "Терминал")]
        guard let projectRoot else { return items }
        let inTree = tree?.leaves ?? []
        for s in projectSessions where s.companionOf == nil {
            guard sessionRoot(s) == projectRoot, !inTree.contains(s.name) else { continue }
            items.append(SplitPickerItem(kind: .session(s.name), label: s.name))
        }
        return items
    }

    enum TerminalDecision: Equatable {
        case focusExisting
        case create
        case replaceForeign(oldShell: String)
    }

    /// Колонка уже показывает шелл этого проекта → фокус; колонки нет →
    /// создать; колонка чужого проекта → заменить (спека «Сайдбар и фокус»).
    static func terminalDecision(companionShell: String?, companionRoot: String?,
                                 projectRoot: String?) -> TerminalDecision {
        switch (companionShell, companionRoot) {
        case (.some(let shell), .some(let root)) where root == projectRoot:
            return .focusExisting
        case (.some(let shell), _):
            return .replaceForeign(oldShell: shell)
        default:
            return .create
        }
    }
}
