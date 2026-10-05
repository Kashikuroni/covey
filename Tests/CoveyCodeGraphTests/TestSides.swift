import Foundation
@testable import CoveyCodeGraph

/// A store over `fake` with a fresh cache (or `cache`).
func makeStore(_ fake: FakeProvider, languages: [any SourceLanguage], changedBasePaths: Set<String> = [],
               limits: GraphLimits = .standard, cache: ParseCache = ParseCache()) -> SourceStore {
    SourceStore(provider: fake, limits: limits, cache: cache, languages: languages,
                changedBasePaths: changedBasePaths)
}

/// One side of `fake` ready for a resolver.
func makeSide(_ fake: FakeProvider, _ side: SourceSide = .head,
              languages: [any SourceLanguage]) async throws -> SideIndex {
    SideIndex(side: side, files: try await fake.files(side), store: makeStore(fake, languages: languages))
}
