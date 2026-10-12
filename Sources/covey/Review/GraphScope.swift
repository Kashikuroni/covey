import Foundation
import CoveyCodeGraph

/// What part of the change the canvas lays out: everything, or only the
/// blocks related to a selected file or directory.
enum GraphScope: Equatable {
    case all
    case file(String)
    case directory(String)

    /// The selected file's neighbour row belongs to a file scope or no scope
    /// at all; a directory scope has no single file to row for.
    var showsNeighbourRow: Bool {
        if case .directory = self { return false }
        return true
    }

    /// The changed files related to the scope: the scope's own files plus,
    /// over `links`, the changed files with a direct link to them — or, when
    /// `transitive`, everything reachable through changed files. Unchanged
    /// files never enter the set; the selected file's neighbour row shows
    /// those. The scope's own files stay even without links.
    func related(files: [String], links: [Link], transitive: Bool) -> Set<String> {
        switch self {
        case .all:
            return Set(files)
        case .file(let path):
            return Self.grow(from: [path], files: files, links: links, transitive: transitive)
        case .directory(let dir):
            let inside = files.filter { $0.hasPrefix(dir + "/") }
            return Self.grow(from: inside, files: files, links: links, transitive: transitive)
        }
    }

    /// `seeds` plus one ring of changed neighbours, or the full ring closure
    /// when `transitive`.
    private static func grow(from seeds: [String], files: [String], links: [Link],
                             transitive: Bool) -> Set<String> {
        let changed = Set(files)
        var adjacency: [String: Set<String>] = [:]
        for link in links where changed.contains(link.from) && changed.contains(link.to) {
            adjacency[link.from, default: []].insert(link.to)
            adjacency[link.to, default: []].insert(link.from)
        }
        var related = Set(seeds)
        var frontier = related
        repeat {
            let next = Set(frontier.flatMap { adjacency[$0] ?? [] }).subtracting(related)
            related.formUnion(next)
            frontier = next
        } while transitive && !frontier.isEmpty
        return related
    }
}
