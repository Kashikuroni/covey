import Foundation
import CoveyKit

/// One sidebar group: a project, or a multi-session workspace view rendered as
/// a nested card.
struct SidebarGroup: Identifiable, Equatable {
    enum Kind: Equatable {
        case splitView(id: ViewID)
        case project(dir: String)
    }

    let kind: Kind
    let sessions: [Session]

    var id: String {
        switch kind {
        case .splitView(let vid): return "splitview:\(vid)"
        case .project(let dir): return "project:\(dir)"
        }
    }

    /// Project directory; nil for a split-view group — drag-reorder and the
    /// ghost row belong only to real projects.
    var dir: String? {
        if case .project(let dir) = kind { return dir }
        return nil
    }
}

/// Sidebar group order. Every multi-leaf view is its own nested group, above
/// the projects (like the single "Split View" group of Split Session, now N).
/// A view's leaves leave their projects and return on teardown — the user's
/// `order` is never touched.
enum SidebarLayout {
    static let splitTitle = "Split View"

    static func groups(projects: [(dir: String, sessions: [Session])],
                       views: [WorkspaceView]) -> [SidebarGroup] {
        let splitViews = views.filter(\.isSplit)
        guard !splitViews.isEmpty else {
            return projects.map { SidebarGroup(kind: .project(dir: $0.dir), sessions: $0.sessions) }
        }

        let flat = projects.flatMap(\.sessions)
        let byName = Dictionary(flat.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let position = Dictionary(uniqueKeysWithValues: flat.enumerated().map { ($1.name, $0) })
        let taken = Set(splitViews.flatMap(\.leaves))

        // Split views ride above the projects, each ordered by its earliest
        // member's sidebar position so a split stays near where its sessions were.
        func earliest(_ v: WorkspaceView) -> Int {
            v.leaves.compactMap { position[$0] }.min() ?? Int.max
        }
        var result = splitViews
            .sorted { earliest($0) < earliest($1) }
            .map { v in
                SidebarGroup(kind: .splitView(id: v.id),
                             sessions: v.leaves.compactMap { byName[$0] })
            }

        for project in projects {
            let rest = project.sessions.filter { !taken.contains($0.name) }
            // A project whose sessions all moved into split views disappears;
            // a registered empty project stays for its ghost row.
            guard !rest.isEmpty || project.sessions.isEmpty else { continue }
            result.append(SidebarGroup(kind: .project(dir: project.dir), sessions: rest))
        }
        return result
    }
}
