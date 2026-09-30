import Foundation

/// One side of the comparison as resolvers see it: the file list, files read
/// on demand, and one resolver per language.
final class SideIndex {
    let side: SourceSide
    let files: Set<String>
    /// Sorted, for deterministic scans.
    let sortedFiles: [String]
    let store: SourceStore
    /// Head path → base path of renamed files, so a base-side resolver can
    /// place a moved file where it used to be. Empty on the head side.
    let formerPaths: [String: String]
    private var resolvers: [String: any ReferenceResolver] = [:]

    init(side: SourceSide, files: [String], store: SourceStore, formerPaths: [String: String] = [:]) {
        self.side = side
        self.files = Set(files)
        self.sortedFiles = self.files.sorted()
        self.store = store
        self.formerPaths = formerPaths
    }

    func contains(_ path: String) -> Bool { files.contains(path) }

    func text(_ path: String) async throws -> String? {
        guard files.contains(path) else { return nil }
        return try await store.text(path, side)
    }

    func parsed(_ path: String) async throws -> ParsedSource? {
        guard files.contains(path) else { return nil }
        return try await store.parsed(path, side)
    }

    func resolver(for language: any SourceLanguage) -> any ReferenceResolver {
        if let known = resolvers[language.id] { return known }
        let made = language.makeResolver(self)
        resolvers[language.id] = made
        return made
    }
}
