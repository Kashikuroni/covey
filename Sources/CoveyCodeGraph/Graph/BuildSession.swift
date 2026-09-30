import Foundation

/// One `build`: reads, resolves and collects links. Created per build, so
/// overlapping builds share nothing but the parse cache.
final class BuildSession {
    private enum Found { case head, base, broken }

    /// Everything seen for one (from, to) pair; the state is decided at the end.
    private struct Pair {
        var head: Set<String>?
        var base: Set<String>?
        var broken: Set<String>?
        var fromUnchanged = false
        var headLines: Set<Int> = []
        var baseLines: Set<Int> = []
        /// Where `from`'s base text lives (a renamed file moved).
        var basePath: String?
    }

    let store: SourceStore
    private let changes: [ChangedSource]
    private let provider: any SourceProvider
    private let limits: GraphLimits
    /// Base path of a deleted or renamed-away file → its node in the graph.
    private let gone: [String: String]
    /// Head paths of added, modified and renamed files.
    private let changedHead: Set<String>
    private let formerPaths: [String: String]
    private var head: SideIndex!
    private var base: SideIndex!
    private var pairs: [LinkKey: Pair] = [:]
    private var complete = true

    init(changes: [ChangedSource], provider: any SourceProvider, limits: GraphLimits,
         cache: ParseCache, languages: [any SourceLanguage]) {
        self.changes = changes.sorted { $0.path < $1.path }
        self.provider = provider
        self.limits = limits
        var gone: [String: String] = [:]
        var formerPaths: [String: String] = [:]
        for change in changes {
            switch change.change {
            case .deleted: gone[change.path] = change.path
            case .renamed(let from):
                gone[from] = change.path
                formerPaths[change.path] = from
            case .added, .modified: break
            }
        }
        self.gone = gone
        self.formerPaths = formerPaths
        self.changedHead = Set(changes.compactMap(\.headPath))
        self.store = SourceStore(provider: provider, limits: limits, cache: cache, languages: languages,
                                 changedBasePaths: Set(changes.compactMap(\.basePath)))
    }

    func run() async throws -> LinkGraph {
        head = SideIndex(side: .head, files: try await provider.files(.head), store: store)
        base = SideIndex(side: .base, files: try await provider.files(.base), store: store,
                         formerPaths: formerPaths)
        for change in changes {
            if let path = change.headPath { try await collectHead(path, fromUnchanged: false) }
            if let basePath = change.basePath { try await collectBase(change.path, at: basePath) }
        }
        try await incoming()
        return try await graph()
    }

    // MARK: - collecting

    /// References in the head text of `path`. A reference whose base target
    /// was deleted or renamed away, and that no longer resolves as deep at
    /// head, is `broken`. From an unchanged file only links into changed
    /// files count.
    private func collectHead(_ path: String, fromUnchanged: Bool) async throws {
        guard let language = store.language(of: path), let source = try await head.parsed(path) else { return }
        let atHead = try await head.resolver(for: language).resolve(source, from: path)
        let atBase = gone.isEmpty ? [] : try await base.resolver(for: language).resolve(source, from: path)
        for (i, line) in source.referenceLines.enumerated() {
            let now = i < atHead.count ? atHead[i] : nil
            if i < atBase.count, let before = atBase[i], let node = gone[before.target],
               (now?.depth ?? -1) < before.depth {
                record(.broken, from: path, to: node, names: before.names, line: line, fromUnchanged: fromUnchanged)
            } else if let now, !fromUnchanged || changedHead.contains(now.target) {
                record(.head, from: path, to: now.target, names: now.names, line: line, fromUnchanged: fromUnchanged)
            }
        }
    }

    /// References in the base text of a changed file, moved onto graph nodes
    /// (a renamed target becomes its new path).
    private func collectBase(_ node: String, at basePath: String) async throws {
        guard let language = store.language(of: basePath),
              let source = try await base.parsed(basePath) else { return }
        let resolved = try await base.resolver(for: language).resolve(source, from: basePath)
        for (i, line) in source.referenceLines.enumerated() {
            guard i < resolved.count, let found = resolved[i] else { continue }
            record(.base, from: node, to: gone[found.target] ?? found.target, names: found.names,
                   line: line, basePath: basePath)
        }
    }

    /// Unchanged files that may use a changed one: found by keyword, parsed at head.
    private func incoming() async throws {
        var words = Set<String>()
        var languageIDs = Set<String>()
        for change in changes {
            if let path = change.headPath, let language = store.language(of: path) {
                languageIDs.insert(language.id)
                words.formUnion(try await head.resolver(for: language).keywords(for: path))
            }
            if let path = change.basePath, change.headPath != path, let language = store.language(of: path) {
                languageIDs.insert(language.id)
                words.formUnion(try await base.resolver(for: language).keywords(for: path))
            }
        }
        guard !words.isEmpty else { return }
        let candidates = Set(try await provider.filesMentioning(words.sorted())).filter { path in
            !changedHead.contains(path) && head.contains(path)
                && store.language(of: path).map { languageIDs.contains($0.id) } == true
        }.sorted()
        for path in candidates {
            try await collectHead(path, fromUnchanged: true)
        }
    }

    private func record(_ found: Found, from: String, to: String, names: [String], line: Int,
                        fromUnchanged: Bool = false, basePath: String? = nil) {
        guard from != to else { return }
        let key = LinkKey(from: from, to: to)
        var pair = pairs[key] ?? Pair()
        switch found {
        case .head:
            pair.head = (pair.head ?? []).union(names)
            pair.headLines.insert(line)
        case .base:
            pair.base = (pair.base ?? []).union(names)
            pair.baseLines.insert(line)
            pair.basePath = basePath
        case .broken:
            pair.broken = (pair.broken ?? []).union(names)
            pair.headLines.insert(line)
        }
        if fromUnchanged { pair.fromUnchanged = true }
        pairs[key] = pair
    }

    // MARK: - result

    private func graph() async throws -> LinkGraph {
        var links: [Link] = []
        var usages: [LinkKey: [UsageSite]] = [:]
        for key in pairs.keys.sorted(by: { ($0.from, $0.to) < ($1.from, $1.to) }) {
            let pair = pairs[key]!
            let state: LinkState
            let names: Set<String>
            if let broken = pair.broken {
                state = .broken
                names = broken.union(pair.head ?? [])
            } else if let headNames = pair.head {
                state = pair.base != nil || pair.fromUnchanged ? .kept : .added
                names = headNames
            } else {
                state = .removed
                names = pair.base ?? []
            }
            links.append(Link(from: key.from, to: key.to, names: names.sorted(), state: state))
            usages[key] = state == .removed
                ? try await usageSites(key.from, textAt: pair.basePath ?? key.from, side: .base,
                                       lines: pair.baseLines, names: names)
                : try await usageSites(key.from, textAt: key.from, side: .head,
                                       lines: pair.headLines, names: names)
        }
        return LinkGraph(links: links, usages: usages, complete: complete,
                         note: complete ? nil : LinkGraph.incompleteNote)
    }

    /// The reference lines plus every line where one of `names` occurs as code.
    private func usageSites(_ from: String, textAt path: String, side: SourceSide,
                            lines: Set<Int>, names: Set<String>) async throws -> [UsageSite] {
        guard let text = try await store.text(path, side) else { return [] }
        var wanted = lines
        if let source = try await store.parsed(path, side) {
            for name in names { wanted.formUnion(source.wordLines[name] ?? []) }
        }
        let texts = Self.lineTexts(text, wanted)
        return wanted.sorted().compactMap { n in texts[n].map { UsageSite(path: from, line: n, text: $0) } }
    }

    /// The wanted 1-based lines, trimmed and cut to `UsageSite.maxTextLength`.
    static func lineTexts(_ text: String, _ wanted: Set<Int>) -> [Int: String] {
        guard let last = wanted.max() else { return [:] }
        let bytes = Array(text.utf8)
        var result: [Int: String] = [:]
        var number = 1
        var start = 0
        while number <= last && start <= bytes.count {
            var end = start
            while end < bytes.count && bytes[end] != .newline { end += 1 }
            if wanted.contains(number) {
                let line = String(decoding: bytes[start..<end], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                result[number] = String(line.prefix(UsageSite.maxTextLength))
            }
            number += 1
            start = end + 1
        }
        return result
    }
}
