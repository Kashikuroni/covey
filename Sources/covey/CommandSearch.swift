import Foundation

struct CommandMatch: Identifiable, Equatable {
    var id: AppCommand { descriptor.id }
    let descriptor: CommandDescriptor
    let score: Int
}

struct CommandSearchGroup: Identifiable, Equatable {
    var id: CommandCategory { category }
    let category: CommandCategory
    let matches: [CommandMatch]
    let score: Int
}

enum CommandSearch {
    static func groups(
        query: String,
        descriptors: [CommandDescriptor] = CommandCatalog.all
    ) -> [CommandSearchGroup] {
        let normalized = normalize(query)
        guard !normalized.isEmpty else {
            return CommandCategory.allCases.compactMap { category in
                let matches = descriptors
                    .filter { $0.category == category }
                    .map { CommandMatch(descriptor: $0, score: 0) }
                guard !matches.isEmpty else { return nil }
                return CommandSearchGroup(category: category, matches: matches, score: 0)
            }
        }

        let latin = normalize(String(query.map(latinize)))
        let queries = Array(Set([normalized, latin])).filter { !$0.isEmpty }
        let catalogIndex = Dictionary(uniqueKeysWithValues:
            descriptors.enumerated().map { ($0.element.id, $0.offset) })

        let matches = descriptors.compactMap { descriptor -> CommandMatch? in
            guard let best = queries.compactMap({ score($0, descriptor) }).max() else {
                return nil
            }
            return CommandMatch(descriptor: descriptor, score: best)
        }

        return CommandCategory.allCases.compactMap { category in
            let categoryMatches = matches
                .filter { $0.descriptor.category == category }
                .sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    return catalogIndex[$0.id, default: .max]
                        < catalogIndex[$1.id, default: .max]
                }
            guard let best = categoryMatches.first?.score else { return nil }
            return CommandSearchGroup(category: category, matches: categoryMatches, score: best)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.category.rawValue < $1.category.rawValue
        }
    }

    private static func score(_ query: String, _ descriptor: CommandDescriptor) -> Int? {
        let title = normalize(descriptor.title)
        let aliases = descriptor.aliases.map(normalize)
        let categories = ([descriptor.category.title] + descriptor.category.aliases)
            .map(normalize)
        var scores: [Int] = []

        if title == query { scores.append(6_100) }
        if aliases.contains(query) { scores.append(6_000) }
        if title.hasPrefix(query) {
            scores.append(5_000 - max(0, title.count - query.count))
        }
        scores += aliases.filter { $0.hasPrefix(query) }
            .map { 4_000 - max(0, $0.count - query.count) }
        if let quality = fuzzyQuality(query, title) { scores.append(3_000 + quality) }
        scores += aliases.compactMap { fuzzyQuality(query, $0).map { 2_000 + $0 } }
        scores += categories.compactMap { fuzzyQuality(query, $0).map { 1_000 + $0 } }
        return scores.max()
    }

    private static func fuzzyQuality(_ pattern: String, _ text: String) -> Int? {
        guard !pattern.isEmpty else { return nil }
        let wanted = Array(pattern)
        let source = Array(text)
        var positions: [Int] = []
        var cursor = 0

        for character in wanted {
            guard let position = source[cursor...].firstIndex(of: character) else {
                return nil
            }
            positions.append(position)
            cursor = position + 1
        }

        let span = (positions.last ?? 0) - (positions.first ?? 0)
        return max(0, 900 - span * 4 - max(0, source.count - wanted.count))
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
