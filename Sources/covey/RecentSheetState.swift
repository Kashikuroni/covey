import Foundation
import CoveyKit

enum RecentSheetFocus: Hashable {
    case search
    case list
}

struct RecentSearchItem: Identifiable, Equatable {
    let session: RecentSession
    let projectRoot: String
    let projectName: String
    var id: String { session.name }
}

func recentSearchItems(current: [RecentSession], retaining: [RecentSession] = [],
                       displayName: (String) -> String) -> [RecentSearchItem] {
    var seen = Set(current.map(\.name))
    let sessions = current + retaining.filter { seen.insert($0.name).inserted }
    return sessions.map { session in
        let root = projectRoot(session.dir)
        return RecentSearchItem(session: session, projectRoot: root,
                                projectName: displayName(root))
    }
}

func recentResults(_ candidates: [RecentSearchItem], query: String,
                   excluding: Set<String> = []) -> [RecentSearchItem] {
    let ordered = candidates.enumerated().sorted { lhs, rhs in
        switch (lhs.element.session.stoppedAt, rhs.element.session.stoppedAt) {
        case let (l?, r?) where l != r: return l > r
        case (_?, nil): return true
        case (nil, _?): return false
        default: return lhs.offset < rhs.offset
        }
    }.map(\.element).filter { !excluding.contains($0.id) }

    guard !query.isEmpty else { return ordered }
    return ordered.filter { item in
        fuzzyMatch(query, item.session.name)
            || item.session.branch.map { fuzzyMatch(query, $0) } == true
            || fuzzyMatch(query, item.projectName)
            || fuzzyMatch(query, item.projectRoot)
    }
}

func recentSheetHeight(rowCount: Int, screenHeight: CGFloat) -> CGFloat {
    min(screenHeight * 0.60, max(250, 142 + CGFloat(max(1, rowCount)) * 66))
}

struct RecentSheetState {
    var query = ""
    private(set) var focus: RecentSheetFocus = .list
    private(set) var selectedName: String?
    private(set) var restoringNames: Set<String> = []
    private(set) var restoredNames: Set<String> = []
    private(set) var failureTriggers: [String: Int] = [:]

    func results(from candidates: [RecentSearchItem]) -> [RecentSearchItem] {
        recentResults(candidates, query: query, excluding: restoredNames)
    }

    mutating func open(rows: [RecentSearchItem]) {
        focus = .list
        reconcile(rows: rows)
    }

    mutating func reconcile(rows: [RecentSearchItem]) {
        if let selectedName, rows.contains(where: { $0.id == selectedName }) { return }
        selectedName = rows.first?.id
    }

    mutating func focusSearch() { focus = .search }

    mutating func commitSearch(rows: [RecentSearchItem]) {
        focus = .list
        reconcile(rows: rows)
    }

    mutating func move(_ delta: Int, rows: [RecentSearchItem]) {
        guard !rows.isEmpty else { selectedName = nil; return }
        let current = rows.firstIndex(where: { $0.id == selectedName }) ?? 0
        selectedName = rows[((current + delta) % rows.count + rows.count) % rows.count].id
    }

    mutating func beginRestore(_ name: String) -> Bool {
        guard !restoringNames.contains(name), !restoredNames.contains(name) else { return false }
        restoringNames.insert(name)
        return true
    }

    mutating func completeRestore(_ name: String, succeeded: Bool,
                                  visibleBefore: [RecentSearchItem],
                                  visibleNow: [RecentSearchItem]? = nil) {
        restoringNames.remove(name)
        if succeeded {
            let oldIndex = visibleBefore.firstIndex(where: { $0.id == name }) ?? 0
            restoredNames.insert(name)
            let remaining = (visibleNow ?? visibleBefore)
                .filter { !restoredNames.contains($0.id) }
            selectedName = remaining.isEmpty ? nil : remaining[min(oldIndex, remaining.count - 1)].id
        } else {
            let current = visibleNow ?? visibleBefore
            selectedName = current.contains(where: { $0.id == name })
                ? name : current.first?.id
            failureTriggers[name, default: 0] &+= 1
        }
    }
}
