import Foundation

struct PythonSyntax: Sendable {
    struct Import: Hashable, Sendable {
        /// Leading dots of a relative import; 0 when absolute.
        var level: Int
        var module: [String]
        /// The name after `from … import`; nil for `import a.b`.
        var name: String?
    }

    /// The file's references, in `referenceLines` order.
    var imports: [Import]
}

struct PythonLanguage: SourceLanguage {
    let id = "python"

    func owns(_ path: String) -> Bool { path.hasSuffix(".py") || path.hasSuffix(".pyi") }

    func parse(_ text: String) -> ParsedSource {
        let tokens = Tokenizer.tokens(PythonLexer.lex(text))
        var parser = PythonParser(tokens: tokens)
        parser.run()
        return ParsedSource(referenceLines: parser.lines, wordLines: Tokenizer.wordLines(tokens),
                            syntax: PythonSyntax(imports: parser.imports))
    }

    func makeResolver(_ side: SideIndex) -> any ReferenceResolver {
        PythonResolver(side: side)
    }
}

/// `import a.b [as x], c` and `from [.]a.b import x [as y], (…)` anywhere in
/// the file — inside functions and `if TYPE_CHECKING:` too.
struct PythonParser {
    let tokens: [Token]
    private(set) var imports: [PythonSyntax.Import] = []
    private(set) var lines: [Int] = []

    init(tokens: [Token]) {
        self.tokens = tokens
    }

    mutating func run() {
        var i = 0
        while i < tokens.count {
            if tokens[i].isWord("from"), let next = fromImport(i + 1) {
                i = next
            } else if tokens[i].isWord("import") {
                i = plainImport(i + 1)
            } else {
                i += 1
            }
        }
    }

    /// nil when the words after `from` are not an import (`raise X from e`):
    /// `import` must follow on the same line or after a `\`.
    private mutating func fromImport(_ start: Int) -> Int? {
        var j = start
        var level = 0
        while j < tokens.count && tokens[j].isPunct(".") {
            level += 1
            j += 1
        }
        let (module, afterModule) = dottedName(j)
        j = afterModule
        guard level > 0 || !module.isEmpty, j > start else { return nil }
        let lastLine = tokens[j - 1].line
        var continued = false
        while j < tokens.count && tokens[j].isPunct("\\") {
            continued = true
            j += 1
        }
        guard j < tokens.count, tokens[j].isWord("import"), continued || tokens[j].line == lastLine else {
            return nil
        }
        j += 1
        let parenthesized = j < tokens.count && tokens[j].isPunct("(")
        if parenthesized { j += 1 }
        while j < tokens.count {
            while j < tokens.count && tokens[j].isPunct("\\") { j += 1 }
            guard j < tokens.count else { break }
            if tokens[j].isPunct("*") {
                add(level: level, module: module, name: "*", line: tokens[j].line)
                j += 1
                break
            }
            guard tokens[j].kind == .word else { break }
            let name = tokens[j]
            j += 1
            if j + 1 < tokens.count && tokens[j].isWord("as") { j += 2 }
            add(level: level, module: module, name: name.text, line: name.line)
            while j < tokens.count && tokens[j].isPunct("\\") { j += 1 }
            guard j < tokens.count, tokens[j].isPunct(",") else { break }
            j += 1
        }
        if parenthesized && j < tokens.count && tokens[j].isPunct(")") { j += 1 }
        return j
    }

    private mutating func plainImport(_ start: Int) -> Int {
        var j = start
        while j < tokens.count {
            while j < tokens.count && tokens[j].isPunct("\\") { j += 1 }
            let (module, next) = dottedName(j)
            guard !module.isEmpty else { break }
            add(level: 0, module: module, name: nil, line: tokens[j].line)
            j = next
            if j + 1 < tokens.count && tokens[j].isWord("as") { j += 2 }
            guard j < tokens.count, tokens[j].isPunct(",") else { break }
            j += 1
        }
        return j
    }

    /// `a.b.c` at `start`: its segments and the index after it. Stops at the
    /// keyword `import` (`from . import x` has no module name).
    private func dottedName(_ start: Int) -> ([String], Int) {
        var segments: [String] = []
        var j = start
        while j < tokens.count, tokens[j].kind == .word, !tokens[j].isWord("import") {
            segments.append(tokens[j].text)
            j += 1
            guard j + 1 < tokens.count, tokens[j].isPunct("."), tokens[j + 1].kind == .word else { break }
            j += 1
        }
        return (segments, j)
    }

    private mutating func add(level: Int, module: [String], name: String?, line: Int) {
        imports.append(PythonSyntax.Import(level: level, module: module, name: name))
        lines.append(line)
    }
}

/// Modules under the repository's search roots; relative imports from the
/// importing file's package.
final class PythonResolver: ReferenceResolver {
    /// Unowned: the side owns its resolvers (`SideIndex.resolver(for:)`), so a
    /// strong reference back would keep the side and its store alive for good.
    private unowned let side: SideIndex
    private var roots: [String]?

    init(side: SideIndex) {
        self.side = side
    }

    /// The repository root, `src/`, every folder with `pyproject.toml` or
    /// `setup.py`, and its `src/`.
    func searchRoots() -> [String] {
        if let roots { return roots }
        var found = ["", "src"]
        for file in side.sortedFiles where ["pyproject.toml", "setup.py"].contains(Paths.basename(file)) {
            let dir = Paths.dirname(file)
            for root in [dir, Paths.join(dir, "src")] where !found.contains(root) { found.append(root) }
        }
        roots = found
        return found
    }

    func resolve(_ source: ParsedSource, from path: String) async throws -> [Resolution?] {
        guard let syntax = source.syntax as? PythonSyntax else { return [] }
        return syntax.imports.map { item in
            guard let name = item.name else {
                return find(item.module, level: 0, from: path)
                    .map { Resolution(target: $0, names: [], depth: item.module.count) }
            }
            // `from a.b import c`: the submodule a/b/c when there is one, else `c` is a name in a.b.
            if name != "*", let submodule = find(item.module + [name], level: item.level, from: path) {
                return Resolution(target: submodule, names: [], depth: item.module.count + 1)
            }
            return find(item.module, level: item.level, from: path)
                .map { Resolution(target: $0, names: [name], depth: item.module.count) }
        }
    }

    /// `foo` for `foo.py`; the package name for `__init__.py`.
    func keywords(for path: String) async throws -> [String] {
        let name = Paths.basename(path)
        let stem = name.hasSuffix(".pyi") ? String(name.dropLast(4))
            : name.hasSuffix(".py") ? String(name.dropLast(3)) : ""
        if stem == "__init__" {
            let package = Paths.basename(Paths.dirname(path))
            return package.isEmpty ? [] : [package]
        }
        return stem.isEmpty ? [] : [stem]
    }

    /// `from . import X` / `from .. import X` reach a package's `__init__`
    /// without naming the package, so `keywords(for:)` cannot find those
    /// files: they are the files of the package that say `from`.
    func scopedKeywords(for path: String) -> [ScopedKeyword] {
        guard ["__init__.py", "__init__.pyi"].contains(Paths.basename(path)) else { return [] }
        return [ScopedKeyword(word: "from", within: Paths.dirname(path))]
    }

    private func find(_ module: [String], level: Int, from path: String) -> String? {
        if level > 0 {
            var dir = Paths.dirname(path)
            for _ in 1..<level {
                guard !dir.isEmpty else { return nil }
                dir = Paths.dirname(dir)
            }
            if module.isEmpty {
                return [Paths.join(dir, "__init__.py"), Paths.join(dir, "__init__.pyi")].first { side.contains($0) }
            }
            return moduleFile(module, under: dir)
        }
        for root in roots(for: path) {
            if let file = moduleFile(module, under: root) { return file }
        }
        return nil
    }

    /// Roots that hold `path` first, deepest first: a file resolves in its own project.
    private func roots(for path: String) -> [String] {
        let all = searchRoots()
        let own = all.filter { Paths.contains($0, path) }.sorted { $0.count > $1.count }
        return own + all.filter { !Paths.contains($0, path) }
    }

    /// `a.b` → `a/b.py`, `a/b.pyi` or `a/b/__init__.py` under `dir`.
    private func moduleFile(_ module: [String], under dir: String) -> String? {
        guard !module.isEmpty else { return nil }
        let stem = Paths.join(dir, module.joined(separator: "/"))
        return [stem + ".py", stem + ".pyi", stem + "/__init__.py"].first { side.contains($0) }
    }
}
