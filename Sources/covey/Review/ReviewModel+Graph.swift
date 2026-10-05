import Foundation
import CoveyGit
import CoveyCodeGraph

/// What the canvas says about the links besides drawing them.
enum GraphNotice: Equatable {
    case incomplete
    /// The build failed and the graph has no links; carries the graph's note.
    case unavailable(String)

    init?(_ graph: LinkGraph) {
        guard !graph.complete else { return nil }
        if graph.note == LinkGraph.incompleteNote {
            self = .incomplete
        } else {
            self = .unavailable(graph.note ?? "links unavailable")
        }
    }

    /// "Links incomplete" / "Links unavailable: <reason>".
    var text: String {
        switch self {
        case .incomplete: return "Links incomplete"
        case .unavailable(let note): return note.prefix(1).uppercased() + note.dropFirst()
        }
    }
}

/// Per-file counts the cards show, over every link.
struct LinkSummary: Equatable {
    var incoming: [String: Int] = [:]
    var outgoing: [String: Int] = [:]
    /// Files still using a deleted or renamed-away file (its `broken` links).
    var brokenUsers: [String: Int] = [:]

    init(_ links: [Link] = []) {
        for link in links {
            incoming[link.to, default: 0] += 1
            outgoing[link.from, default: 0] += 1
            if link.state == .broken { brokenUsers[link.to, default: 0] += 1 }
        }
    }
}

/// The link graph of the comparison (Review spec part 3, «Обновление»):
/// built in the background when the comparison's fingerprint changes, at
/// most once per `graphInterval`, only while Review is on screen. A result
/// whose generation moved on — another comparison, another worktree, the
/// sessions shown — is dropped.
extension ReviewModel {
    /// Links as the layout and the visibility rules take them; nil while
    /// there is no graph yet or it is unavailable.
    var graphLinks: [Link]? {
        guard let linkGraph, !(GraphNotice(linkGraph)?.isUnavailable ?? false) else { return nil }
        return linkGraph.links
    }

    var graphNotice: GraphNotice? { linkGraph.flatMap(GraphNotice.init) }

    /// Builds links for the current comparison unless the shown (or running)
    /// build is already for its fingerprint; `force` rebuilds anyway (Retry).
    func requestGraph(force: Bool = false) {
        guard isVisible, phase == .ready, let state else { return }
        let target = state.fingerprint
        if !force, target == (graphPendingFor ?? graphShownFor) { return }
        graphGeneration += 1
        let generation = graphGeneration
        graphTask?.cancel()
        graphPendingFor = target
        graphUpdating = true
        let wait = graphStartedAt.map { max(.zero, graphInterval - (ContinuousClock.now - $0)) } ?? .zero
        let worktree = worktree
        let comparison = record.comparison
        let graphs = graphs
        graphTask = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard let self, generation == self.graphGeneration, !Task.isCancelled else { return }
            self.graphStartedAt = .now
            let graph = await graphs.build(worktree: worktree, comparison: comparison, state: state)
            guard generation == self.graphGeneration else { return }
            self.setLinkGraph(graph)
            self.graphShownFor = target
            self.graphPendingFor = nil
            self.graphUpdating = false
            self.graphTask = nil
        }
    }

    /// "Retry" under "Links unavailable".
    func retryGraph() { requestGraph(force: true) }

    /// Abandons a running build: its result, if it still arrives, is dropped.
    func dropGraphWork() {
        graphGeneration += 1
        graphTask?.cancel()
        graphTask = nil
        graphPendingFor = nil
        graphUpdating = false
    }

    /// Review left the screen (the sessions, a covered window) or came back.
    func graphVisibilityChanged() {
        if isVisible { requestGraph() } else { dropGraphWork() }
    }

    func setLinkGraph(_ graph: LinkGraph?) {
        linkGraph = graph
        linkSummary = LinkSummary(graph?.links ?? [])
    }

    /// The neighbour row belongs to the selection and shows while either
    /// link setting is on; hovering never adds it.
    var showsNeighbourRow: Bool {
        selectedPath != nil && (linkSettings.showLinks || linkSettings.linksOnFocus)
    }

    var linkVisibility: LinkVisibility {
        LinkVisibility.resolve(showLinks: linkSettings.showLinks, linksOnFocus: linkSettings.linksOnFocus,
                               hovered: hoveredPath, selected: selectedPath,
                               changed: Set(files.map(\.path)), links: graphLinks ?? [])
    }

    /// Hover in and out of a card; leaving one never clears another's hover.
    func hover(_ path: String, inside: Bool) {
        if inside {
            hoveredPath = path
        } else if hoveredPath == path {
            hoveredPath = nil
        }
    }

    /// "+N more" on the selected card.
    func expandNeighbours() { neighboursExpanded = true }
}

private extension GraphNotice {
    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}
