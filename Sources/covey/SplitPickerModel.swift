import Foundation
import CoveyKit

/// Чистая логика модалки сплита (spec «Модалка выбора»): сессии проекта в
/// порядке `orderedSessions()`, исключая уже открытые панели и невидимые
/// (`companionOf != nil`, `hidden`). Терминал-зона живёт отдельной командой.
struct SplitPickerItem: Equatable, Identifiable {
    enum Kind: Equatable { case session(String) }
    let kind: Kind
    var label: String
    var id: String {
        switch kind {
        case .session(let name): return "session:\(name)"
        }
    }
}

enum SplitPicker {
    /// `occupied` — agent-панели, уже открытые в активной View (`AppModel.agentPanes`).
    /// `projectSessions` приходит в порядке сайдбара и этот порядок сохраняется.
    static func items(projectSessions: [Session], occupied: [String],
                      projectRoot: String?) -> [SplitPickerItem] {
        guard let projectRoot else { return [] }
        let taken = Set(occupied)
        var items: [SplitPickerItem] = []
        for s in projectSessions where s.companionOf == nil && s.hidden != true {
            guard sessionRoot(s) == projectRoot, !taken.contains(s.name) else { continue }
            items.append(SplitPickerItem(kind: .session(s.name), label: s.name))
        }
        return items
    }
}
