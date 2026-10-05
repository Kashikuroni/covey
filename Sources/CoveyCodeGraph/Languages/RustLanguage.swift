import Foundation

struct RustSyntax: Sendable {
    /// `mod x;` (file-backed) or `mod x { … }` (inline).
    struct Module: Hashable, Sendable {
        /// From the file's own module: `mod a { mod b; }` gives [a] and [a, b].
        var path: [String]
        var inline: Bool
    }

    /// A path as written: a `use` leaf or an `a::b::c` path in code.
    struct PathRef: Hashable, Sendable {
        /// Inline modules around the reference, from the file's module.
        var scope: [String]
        var segments: [String]
        /// Written with a leading `::`: a crate name follows.
        var global: Bool
        /// From a `use` tree: the first segment may be a child module.
        var isUse: Bool
    }

    var modules: [Module]
    /// The file's references, in `referenceLines` order.
    var paths: [PathRef]
}

struct RustLanguage: SourceLanguage {
    let id = "rust"

    func owns(_ path: String) -> Bool { path.hasSuffix(".rs") }

    func parse(_ text: String) -> ParsedSource {
        let tokens = Tokenizer.tokens(RustLexer.lex(text))
        var parser = RustParser(tokens: tokens)
        parser.run()
        return ParsedSource(referenceLines: parser.lines, wordLines: Tokenizer.wordLines(tokens),
                            syntax: RustSyntax(modules: parser.modules, paths: parser.paths))
    }

    func makeResolver(_ side: SideIndex) -> any ReferenceResolver {
        RustResolver(side: side)
    }
}

/// Collects `mod` declarations, flattened `use` trees and `a::b` paths in
/// code, tracking inline `mod x { … }` blocks by brace depth.
struct RustParser {
    let tokens: [Token]
    private(set) var modules: [RustSyntax.Module] = []
    private(set) var paths: [RustSyntax.PathRef] = []
    private(set) var lines: [Int] = []
    private var scopes: [(name: String, depth: Int)] = []
    private var depth = 0

    /// Deeper `use` groups are skipped rather than recursed into.
    private static let maxGroupNesting = 32

    init(tokens: [Token]) {
        self.tokens = tokens
    }

    mutating func run() {
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token.isPunct("{") {
                depth += 1
                i += 1
            } else if token.isPunct("}") {
                if let last = scopes.last, last.depth == depth { scopes.removeLast() }
                depth -= 1
                i += 1
            } else if token.isWord("mod"), i + 2 < tokens.count, tokens[i + 1].kind == .word,
                      tokens[i + 2].isPunct(";") || tokens[i + 2].isPunct("{") {
                let name = tokens[i + 1].text
                let inline = tokens[i + 2].isPunct("{")
                modules.append(RustSyntax.Module(path: scopes.map(\.name) + [name], inline: inline))
                if inline {
                    depth += 1
                    scopes.append((name, depth))
                }
                i += 3
            } else if token.isWord("use") {
                i = useStatement(from: i + 1)
            } else if token.kind == .word, i + 2 < tokens.count, tokens[i + 1].isPunct("::"),
                      tokens[i + 2].kind == .word, !(i > 0 && tokens[i - 1].isPunct("::")),
                      Self.canStartPath(token.text) {
                i = codePath(from: i, global: false)
            } else if token.isPunct("::"), i + 3 < tokens.count, tokens[i + 1].kind == .word,
                      tokens[i + 2].isPunct("::"),
                      !(i > 0 && (tokens[i - 1].kind == .word || tokens[i - 1].isPunct(">"))) {
                i = codePath(from: i + 1, global: true)   // `::acme_core::x`
            } else {
                i += 1
            }
        }
    }

    /// `a::b::c` starting at `start`; returns the index after it.
    private mutating func codePath(from start: Int, global: Bool) -> Int {
        var segments = [tokens[start].text]
        var j = start + 1
        while j + 1 < tokens.count, tokens[j].isPunct("::"), tokens[j + 1].kind == .word {
            segments.append(tokens[j + 1].text)
            j += 2
        }
        add(segments, line: tokens[j - 1].line, global: global, isUse: false)
        return j
    }

    /// `crate`, `self`, `super` or a lowercase name (a crate); `Self::`, `Vec::` are not module paths.
    private static func canStartPath(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first else { return false }
        return first == "_" || ("a"..."z").contains(first)
    }

    /// Flattens one `use` tree; returns the index after its `;`.
    private mutating func useStatement(from start: Int) -> Int {
        var j = start
        var global = false
        if j < tokens.count && tokens[j].isPunct("::") {
            global = true
            j += 1
        }
        tree(&j, prefix: [], global: global, nesting: 0)
        while j < tokens.count && !tokens[j].isPunct(";") { j += 1 }
        return j + 1
    }

    private mutating func tree(_ j: inout Int, prefix: [String], global: Bool, nesting: Int) {
        var segments = prefix
        while j < tokens.count {
            let token = tokens[j]
            if token.isPunct("{") {
                guard nesting < Self.maxGroupNesting else { return }
                j += 1
                while j < tokens.count && !tokens[j].isPunct("}") && !tokens[j].isPunct(";") {
                    let before = j
                    tree(&j, prefix: segments, global: global, nesting: nesting + 1)
                    if j < tokens.count && tokens[j].isPunct(",") { j += 1 }
                    if j == before { j += 1 }
                }
                if j < tokens.count && tokens[j].isPunct("}") { j += 1 }
                return
            }
            if token.isPunct("*") {
                add(segments + ["*"], line: token.line, global: global, isUse: true)
                j += 1
                return
            }
            guard token.kind == .word else { return }
            j += 1
            if j < tokens.count && tokens[j].isPunct("::") {
                segments.append(token.text)
                j += 1
                continue
            }
            let leaf = token.text == "self" && !segments.isEmpty ? segments : segments + [token.text]
            if j + 1 < tokens.count && tokens[j].isWord("as") { j += 2 }
            add(leaf, line: token.line, global: global, isUse: true)
            return
        }
    }

    private mutating func add(_ segments: [String], line: Int, global: Bool, isUse: Bool) {
        paths.append(RustSyntax.PathRef(scope: scopes.map(\.name), segments: segments,
                                        global: global, isUse: isUse))
        lines.append(line)
    }
}
