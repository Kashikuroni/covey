import Foundation

/// Finds links between the files of a change. One builder lives with one
/// review model: it owns the parse cache, so a rebuild only re-parses files
/// whose content changed.
public actor LinkGraphBuilder {
    public let limits: GraphLimits
    nonisolated let cache = ParseCache()
    /// Counts `build` calls; only the latest trims the cache.
    private var latest = 0

    /// Every supported language; files of any other language are nodes
    /// without links.
    static let languages: [any SourceLanguage] = [RustLanguage(), PythonLanguage(), ScriptLanguage(), SwiftLanguage()]

    public init(limits: GraphLimits = .standard) {
        self.limits = limits
    }

    /// Links of every changed file (outgoing, head and base) and into every
    /// changed file from unchanged ones. Never throws: a failure yields
    /// `LinkGraph.unavailable(reason)`; a spent budget, the candidate cap or a
    /// cancelled task yield an incomplete graph with what was found.
    public func build(changes: [ChangedSource], provider: any SourceProvider) async -> LinkGraph {
        latest += 1
        let mine = latest
        let session = BuildSession(changes: changes, provider: provider, limits: limits,
                                   cache: cache, languages: Self.languages)
        do {
            let graph = try await session.run()
            // `run` suspends, so builds overlap: only the newest one knows
            // which parses are still wanted.
            if graph.complete && mine == latest { cache.retain(only: session.store.usedKeys) }
            return graph
        } catch {
            if error is CancellationError || Task.isCancelled {
                return LinkGraph(links: [], usages: [:], complete: false, note: LinkGraph.incompleteNote)
            }
            return .unavailable("\(error)")
        }
    }
}
