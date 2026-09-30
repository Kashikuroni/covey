import Foundation

/// Reads and parses files for one build. A file that did not change is read
/// on the head side even when base is asked for: the text is the same, and
/// head reads are the cheap ones (the working tree on disk).
final class SourceStore {
    private struct Key: Hashable {
        let path: String
        let side: SourceSide
    }

    let provider: any SourceProvider
    let limits: GraphLimits
    let cache: ParseCache
    let languages: [any SourceLanguage]
    /// Base paths whose text differs from head: modified, deleted, renamed-from.
    let changedBasePaths: Set<String>
    /// Cache keys this build used; the builder keeps only these afterwards.
    private(set) var usedKeys: Set<ParseKey> = []
    private var texts: [Key: String?] = [:]
    private var parsed: [Key: ParsedSource?] = [:]

    init(provider: any SourceProvider, limits: GraphLimits, cache: ParseCache,
         languages: [any SourceLanguage], changedBasePaths: Set<String>) {
        self.provider = provider
        self.limits = limits
        self.cache = cache
        self.languages = languages
        self.changedBasePaths = changedBasePaths
    }

    func language(of path: String) -> (any SourceLanguage)? {
        languages.first { $0.owns(path) }
    }

    /// The file's text, or nil when it is missing, binary or over the size limit.
    func text(_ path: String, _ side: SourceSide) async throws -> String? {
        let key = readKey(path, side)
        if let known = texts[key] { return known }
        var text = try await provider.text(path, key.side)
        if let read = text, read.utf8.count > limits.maxFileBytes || read.utf8.contains(0) {
            text = nil
        }
        texts.updateValue(text, forKey: key)
        return text
    }

    /// The file parsed by its language; nil for other languages and unreadable files.
    func parsed(_ path: String, _ side: SourceSide) async throws -> ParsedSource? {
        let key = readKey(path, side)
        if let known = parsed[key] { return known }
        var result: ParsedSource?
        if let language = language(of: path), let text = try await text(path, side) {
            let cacheKey = ParseKey(path: path, text: text)
            usedKeys.insert(cacheKey)
            if let hit = cache.value(for: cacheKey) {
                result = hit
            } else {
                let fresh = language.parse(text)
                cache.store(fresh, for: cacheKey)
                result = fresh
            }
        }
        parsed.updateValue(result, forKey: key)
        return result
    }

    private func readKey(_ path: String, _ side: SourceSide) -> Key {
        Key(path: path, side: side == .base && !changedBasePaths.contains(path) ? .head : side)
    }
}
