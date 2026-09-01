import Foundation
import CoveyKit

/// Одна группа сайдбара: проект или псевдо-проект «Split View».
struct SidebarGroup: Identifiable, Equatable {
    enum Kind: Equatable {
        case splitView
        case project(dir: String)
    }

    let kind: Kind
    let sessions: [Session]

    var id: String {
        switch kind {
        case .splitView: return "splitview"
        case .project(let dir): return "project:\(dir)"
        }
    }

    /// Каталог проекта; nil у Split View — драг-перестановка и ghost-строка
    /// принадлежат только настоящим проектам.
    var dir: String? {
        if case .project(let dir) = kind { return dir }
        return nil
    }
}

/// Порядок групп сайдбара. Split View — отдельная сущность над проектами:
/// сессии сплита показываются в нём (в порядке обхода дерева) и уходят из
/// своих проектов, а после разбора сплита возвращаются на прежние места —
/// пользовательский `order` при этом не трогается.
enum SidebarLayout {
    static let splitTitle = "Split View"

    static func groups(projects: [(dir: String, sessions: [Session])],
                       splitLeaves: [String]) -> [SidebarGroup] {
        guard !splitLeaves.isEmpty else {
            return projects.map { SidebarGroup(kind: .project(dir: $0.dir),
                                               sessions: $0.sessions) }
        }
        let byName = Dictionary(projects.flatMap(\.sessions).map { ($0.name, $0) },
                                uniquingKeysWith: { first, _ in first })
        let taken = Set(splitLeaves)
        var result = [SidebarGroup(kind: .splitView,
                                   sessions: splitLeaves.compactMap { byName[$0] })]
        for project in projects {
            let rest = project.sessions.filter { !taken.contains($0.name) }
            // Проект, чьи сессии целиком уехали в сплит, из списка уходит;
            // зарегистрированный пустой остаётся ради ghost-строки.
            guard !rest.isEmpty || project.sessions.isEmpty else { continue }
            result.append(SidebarGroup(kind: .project(dir: project.dir), sessions: rest))
        }
        return result
    }
}
