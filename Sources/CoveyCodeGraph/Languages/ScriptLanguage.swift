import Foundation

struct ScriptSyntax: Sendable {
    struct Import: Hashable, Sendable {
        var specifier: String
        var names: [String]
    }

    /// The file's references, in `referenceLines` order.
    var imports: [Import]
}

/// TypeScript and JavaScript.
struct ScriptLanguage: SourceLanguage {
    let id = "script"

    /// Resolution order when a specifier has no extension; `.d.ts` counts as TS.
    static let extensions = [".ts", ".tsx", ".d.ts", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs"]

    func owns(_ path: String) -> Bool { Self.extensions.contains { path.hasSuffix($0) } }

    func parse(_ text: String) -> ParsedSource {
        let tokens = Tokenizer.tokens(ScriptLexer.lex(text))
        var parser = ScriptParser(tokens: tokens)
        parser.run()
        return ParsedSource(referenceLines: parser.lines, wordLines: Tokenizer.wordLines(tokens),
                            syntax: ScriptSyntax(imports: parser.imports))
    }

    func makeResolver(_ side: SideIndex) -> any ReferenceResolver {
        ScriptResolver(side: side)
    }
}

/// `import … from 'x'`, `import 'x'`, `export … from 'x'`, `import('x')`,
/// `require('x')`, `import x = require('x')`. Names: named imports by their
/// local name, the default import's local name, `* as ns` as `ns`; re-exports
/// by the name taken from the target.
struct ScriptParser {
    let tokens: [Token]
    private(set) var imports: [ScriptSyntax.Import] = []
    private(set) var lines: [Int] = []

    init(tokens: [Token]) {
        self.tokens = tokens
    }

    mutating func run() {
        var i = 0
        while i < tokens.count {
            let afterDot = i > 0 && tokens[i - 1].isPunct(".")
            if tokens[i].isWord("import") && !afterDot {
                i = importStatement(i + 1)
            } else if tokens[i].isWord("export") && !afterDot {
                i = exportStatement(i + 1)
            } else if tokens[i].isWord("require") && !afterDot, let (literal, next) = call(i + 1) {
                add(literal, names: [])
                i = next
            } else {
                i += 1
            }
        }
    }

    private mutating func importStatement(_ start: Int) -> Int {
        guard start < tokens.count else { return start }
        if tokens[start].isPunct("(") {   // import('x')
            if start + 2 < tokens.count, tokens[start + 1].kind == .string,
               tokens[start + 2].isPunct(")") || tokens[start + 2].isPunct(",") {
                add(tokens[start + 1], names: [])
                return start + 3
            }
            return start + 1
        }
        if tokens[start].kind == .string {   // import 'x'
            add(tokens[start], names: [])
            return start + 1
        }
        var names: [String] = []
        var k = start
        if tokens[k].isWord("type"), k + 1 < tokens.count, !tokens[k + 1].isWord("from"),
           !tokens[k + 1].isPunct(","), !tokens[k + 1].isPunct("=") {
            k += 1   // `import type …`, not a default import named `type`
        }
        if k < tokens.count, tokens[k].kind == .word, !tokens[k].isWord("from") {
            let local = tokens[k].text
            k += 1
            if k < tokens.count && tokens[k].isPunct("=") {   // import x = require('x')
                if k + 1 < tokens.count, tokens[k + 1].isWord("require"), let (literal, next) = call(k + 2) {
                    add(literal, names: [local])
                    return next
                }
                return k
            }
            names.append(local)
            if k < tokens.count && tokens[k].isPunct(",") { k += 1 }
        }
        if k < tokens.count && tokens[k].isPunct("*") {
            guard k + 2 < tokens.count, tokens[k + 1].isWord("as"), tokens[k + 2].kind == .word else { return k }
            names.append(tokens[k + 2].text)
            k += 3
        } else if k < tokens.count && tokens[k].isPunct("{") {
            k = specifiers(k + 1, localNames: true, into: &names)
        }
        guard k + 1 < tokens.count, tokens[k].isWord("from"), tokens[k + 1].kind == .string else { return k }
        add(tokens[k + 1], names: names)
        return k + 2
    }

    /// Only `export … from 'x'` refers to another file.
    private mutating func exportStatement(_ start: Int) -> Int {
        var k = start
        if k < tokens.count && tokens[k].isWord("type") { k += 1 }
        var names: [String] = []
        if k < tokens.count && tokens[k].isPunct("*") {
            k += 1
            if k + 1 < tokens.count, tokens[k].isWord("as"), tokens[k + 1].kind == .word {
                names = [tokens[k + 1].text]
                k += 2
            } else {
                names = ["*"]
            }
        } else if k < tokens.count && tokens[k].isPunct("{") {
            k = specifiers(k + 1, localNames: false, into: &names)
        } else {
            return start
        }
        guard k + 1 < tokens.count, tokens[k].isWord("from"), tokens[k + 1].kind == .string else { return k }
        add(tokens[k + 1], names: names)
        return k + 2
    }

    /// `a, b as c, type T }` from just after `{`; returns the index after `}`.
    private func specifiers(_ start: Int, localNames: Bool, into names: inout [String]) -> Int {
        var k = start
        while k < tokens.count && !tokens[k].isPunct("}") && !tokens[k].isPunct(";") {
            if tokens[k].isWord("type"), k + 1 < tokens.count, tokens[k + 1].kind == .word,
               !tokens[k + 1].isWord("as") {
                k += 1
            }
            guard tokens[k].kind == .word else {
                k += 1
                continue
            }
            let imported = tokens[k].text
            var local = imported
            k += 1
            if k + 1 < tokens.count, tokens[k].isWord("as"), tokens[k + 1].kind == .word {
                local = tokens[k + 1].text
                k += 2
            }
            names.append(localNames ? local : imported)
            if k < tokens.count && tokens[k].isPunct(",") { k += 1 }
        }
        return k < tokens.count && tokens[k].isPunct("}") ? k + 1 : k
    }

    /// `('x')` at `start`: the literal and the index after `)`.
    private func call(_ start: Int) -> (Token, Int)? {
        guard start + 2 < tokens.count, tokens[start].isPunct("("), tokens[start + 1].kind == .string,
              tokens[start + 2].isPunct(")") else { return nil }
        return (tokens[start + 1], start + 3)
    }

    private mutating func add(_ literal: Token, names: [String]) {
        imports.append(ScriptSyntax.Import(specifier: literal.text, names: names))
        lines.append(literal.line)
    }
}
