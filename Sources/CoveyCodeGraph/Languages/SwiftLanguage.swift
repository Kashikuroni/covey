import Foundation

struct SwiftSyntax: Sendable {
    /// Types and functions declared at column 0.
    var declarations: [String]
    /// Distinct identifiers of 3+ characters: the file's references.
    var words: [String]
}

/// Swift has no imports between files of a module, so a reference is a
/// name: A uses B when A mentions a top-level name that only B declares.
struct SwiftLanguage: SourceLanguage {
    let id = "swift"

    private static let declarationKeywords: Set<String> = [
        "class", "struct", "enum", "protocol", "actor", "typealias", "func",
    ]
    private static let modifiers: Set<String> = [
        "public", "private", "fileprivate", "internal", "package", "open", "final",
        "indirect", "nonisolated", "distributed",
    ]

    func owns(_ path: String) -> Bool { path.hasSuffix(".swift") }

    func parse(_ text: String) -> ParsedSource {
        let tokens = Tokenizer.tokens(SwiftLexer.lex(text))
        let wordLines = Tokenizer.wordLines(tokens)
        let words = wordLines.keys.filter { $0.utf8.count >= 3 }.sorted()
        return ParsedSource(referenceLines: words.map { wordLines[$0]![0] },
                            wordLines: wordLines,
                            syntax: SwiftSyntax(declarations: Self.declarations(tokens), words: words))
    }

    func makeResolver(_ side: SideIndex) -> any ReferenceResolver {
        SwiftResolver(side: side)
    }

    /// `(@attr(…) | modifier)* keyword Name` starting at column 0.
    /// `extension` is not a keyword here: extensions declare nothing.
    static func declarations(_ tokens: [Token]) -> [String] {
        var names: [String] = []
        var i = 0
        while i < tokens.count {
            guard tokens[i].column == 0 else {
                i += 1
                continue
            }
            var j = i
            while j < tokens.count {
                if tokens[j].isPunct("@"), j + 1 < tokens.count, tokens[j + 1].kind == .word {
                    j += 2
                    if j < tokens.count && tokens[j].isPunct("(") { j = afterParens(tokens, j) }
                } else if tokens[j].kind == .word && modifiers.contains(tokens[j].text) {
                    j += 1
                } else {
                    break
                }
            }
            if j + 1 < tokens.count, tokens[j].kind == .word, declarationKeywords.contains(tokens[j].text),
               tokens[j + 1].kind == .word, let first = tokens[j + 1].text.unicodeScalars.first,
               first == "_" || CharacterSet.letters.contains(first) {
                names.append(tokens[j + 1].text)
            }
            i = j + 1
        }
        return names
    }

    /// Index after the `)` matching the `(` at `open`.
    private static func afterParens(_ tokens: [Token], _ open: Int) -> Int {
        var depth = 0
        var k = open
        while k < tokens.count {
            if tokens[k].isPunct("(") { depth += 1 }
            if tokens[k].isPunct(")") {
                depth -= 1
                if depth == 0 { return k + 1 }
            }
            k += 1
        }
        return k
    }
}

final class SwiftResolver: ReferenceResolver {
    /// Unowned: the side owns its resolvers (`SideIndex.resolver(for:)`), so a
    /// strong reference back would keep the side and its store alive for good.
    private unowned let side: SideIndex
    private var index: [String: String]?

    init(side: SideIndex) {
        self.side = side
    }

    /// Declared name → its file, over every Swift file of the side. A name
    /// declared in two files, or shorter than 3 characters, is left out.
    func declarations() async throws -> [String: String] {
        if let index { return index }
        var owners: [String: Set<String>] = [:]
        for path in side.sortedFiles where path.hasSuffix(".swift") {
            guard let syntax = try await side.parsed(path)?.syntax as? SwiftSyntax else { continue }
            for name in syntax.declarations where name.utf8.count >= 3 {
                owners[name, default: []].insert(path)
            }
        }
        let unique = owners.compactMapValues { $0.count == 1 ? $0.first : nil }
        index = unique
        return unique
    }

    func resolve(_ source: ParsedSource, from path: String) async throws -> [Resolution?] {
        guard let syntax = source.syntax as? SwiftSyntax else { return [] }
        let index = try await declarations()
        return syntax.words.map { word in index[word].map { Resolution(target: $0, names: [word]) } }
    }

    func keywords(for path: String) async throws -> [String] {
        guard let syntax = try await side.parsed(path)?.syntax as? SwiftSyntax else { return [] }
        let index = try await declarations()
        return syntax.declarations.filter { index[$0] == path }
    }
}
