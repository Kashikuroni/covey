import Foundation
@testable import CoveyCodeGraph

/// Builds the graph of every difference between `fake`'s sides.
func buildGraph(_ fake: FakeProvider, renames: [String: String] = [:],
                limits: GraphLimits = .standard) async -> LinkGraph {
    await LinkGraphBuilder(limits: limits).build(changes: fake.changes(renames: renames), provider: fake)
}

/// `from → to state [names]`, one per link, in graph order.
func describe(_ graph: LinkGraph) -> [String] {
    graph.links.map { link in
        "\(link.from) → \(link.to) \(link.state)"
            + (link.names.isEmpty ? "" : " [\(link.names.joined(separator: ", "))]")
    }
}
