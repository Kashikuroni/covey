import Foundation
import CoveyKit

/// Чистая логика модалки сплита (spec «Модалка выбора»): пункт «Терминал»
/// первым, ниже — сессии проекта в порядке `orderedSessions()`, исключая
/// уже открытые панели и невидимые (`companionOf != nil`).
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
    /// `occupied` — agent-панели, уже открытые в окне (`AppModel.agentPanes`).
    /// Не дерево: при одной панели дерева нет, а сессия всё равно занята —
    /// предлагать её к сплиту нельзя. `projectSessions` приходит в порядке
    /// сайдбара и этот порядок сохраняется.
    static func items(projectSessions: [Session], occupied: [String],
                      projectRoot: String?) -> [SplitPickerItem] {
        var items = [SplitPickerItem(kind: .terminal, label: "Терминал")]
        guard let projectRoot else { return items }
        let taken = Set(occupied)
        for s in projectSessions where s.companionOf == nil {
            guard sessionRoot(s) == projectRoot, !taken.contains(s.name) else { continue }
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
