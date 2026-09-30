import Foundation

/// Finds links between the files of a change. One builder lives with one
/// review model: it owns the parse cache, so a rebuild only re-parses files
/// whose content changed.
public actor LinkGraphBuilder {
    public let limits: GraphLimits
    nonisolated let cache = ParseCache()

    /// Every supported language; files of any other language are nodes
    /// without links.
    static let languages: [any SourceLanguage] = [SwiftLanguage()]

    public init(limits: GraphLimits = .standard) {
        self.limits = limits
    }

    /// Links of every changed file (outgoing, head and base) and into every
    /// changed file from unchanged ones. Never throws: a failure yields
    /// `LinkGraph.unavailable(reason)`.
    public func build(changes: [ChangedSource], provider: any SourceProvider) async -> LinkGraph {
        let session = BuildSession(changes: changes, provider: provider, limits: limits,
                                   cache: cache, languages: Self.languages)
        do {
            let graph = try await session.run()
            if graph.complete { cache.retain(only: session.store.usedKeys) }
            return graph
        } catch {
            return .unavailable("\(error)")
        }
    }
}
