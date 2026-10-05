import Foundation

/// A `package.json` with a `name`: bare specifiers `name` and `name/sub` land in it.
struct ScriptPackage: Equatable {
    var name: String
    var dir: String
    /// Entry candidates in order: `exports["."]`, `module`, `main`, `src/index`, `index`.
    var entries: [String]
}

/// Effective `compilerOptions` of one tsconfig after its `extends` chain.
struct ScriptConfig: Equatable {
    struct Alias: Equatable {
        var pattern: String
        var targets: [String]
    }

    var baseUrl: String?
    var paths: [Alias] = []
    /// The folder of the config that defined `paths`; targets are relative
    /// to it when there is no `baseUrl`.
    var pathsDir: String

    /// `paths` targets for `spec`: an exact pattern wins, else the `*` pattern
    /// with the longest prefix.
    func candidates(for spec: String) -> [String] {
        var best: (alias: Alias, captured: String, prefix: Int)?
        for alias in paths {
            guard alias.pattern.contains("*") else {
                if alias.pattern == spec {
                    best = (alias, "", Int.max)
                    break
                }
                continue
            }
            let parts = alias.pattern.split(separator: "*", maxSplits: 1, omittingEmptySubsequences: false)
            let prefix = String(parts[0])
            let suffix = parts.count > 1 ? String(parts[1]) : ""
            guard spec.hasPrefix(prefix), spec.hasSuffix(suffix),
                  spec.count >= prefix.count + suffix.count else { continue }
            if best == nil || prefix.count > best!.prefix {
                best = (alias, String(spec.dropFirst(prefix.count).dropLast(suffix.count)), prefix.count)
            }
        }
        guard let best else { return [] }
        let root = baseUrl ?? pathsDir
        return best.alias.targets.compactMap {
            Paths.normalize(root, $0.replacingOccurrences(of: "*", with: best.captured))
        }
    }
}

/// Relative specifiers, tsconfig/jsconfig aliases, then workspace packages;
/// any other bare specifier is an external package and ignored.
final class ScriptResolver: ReferenceResolver {
    /// Unowned: the side owns its resolvers (`SideIndex.resolver(for:)`), so a
    /// strong reference back would keep the side and its store alive for good.
    private unowned let side: SideIndex
    private var packages: [ScriptPackage]?
    private var configsByDir: [String: ScriptConfig?] = [:]
    private var configsByFile: [String: ScriptConfig?] = [:]

    init(side: SideIndex) {
        self.side = side
    }

    func resolve(_ source: ParsedSource, from path: String) async throws -> [Resolution?] {
        guard let syntax = source.syntax as? ScriptSyntax else { return [] }
        var resolved: [Resolution?] = []
        for item in syntax.imports {
            resolved.append(try await resolve(item.specifier, from: path)
                .map { Resolution(target: $0, names: item.names) })
        }
        return resolved
    }

    /// The file name without extension (the folder name for `index.*`), and
    /// the package name when the file is a workspace package's entry.
    func keywords(for path: String) async throws -> [String] {
        let stem = Self.stem(of: path)
        var words = [stem == "index" ? Paths.basename(Paths.dirname(path)) : stem]
        // An explicit `./dir/index` specifier names the file, not the folder:
        // `index` also finds importers that say neither the folder nor
        // `from`/`require` inside it; resolution drops the over-selection.
        if stem == "index" { words.append("index") }
        for package in try await workspacePackages() where entry(of: package) == path {
            words.append(package.name)
        }
        return words.filter { !$0.isEmpty }
    }

    /// `import … from '.'`, `from '..'` and `require('..')` reach a folder's
    /// `index.*` without naming the folder, so `keywords(for:)` cannot find
    /// those files: they are the files of the folder that say `from` or `require`.
    func scopedKeywords(for path: String) -> [ScopedKeyword] {
        guard Self.stem(of: path) == "index" else { return [] }
        let folder = Paths.dirname(path)
        return [ScopedKeyword(word: "from", within: folder), ScopedKeyword(word: "require", within: folder)]
    }

    /// The file name without its script extension.
    private static func stem(of path: String) -> String {
        let name = Paths.basename(path)
        if name.hasSuffix(".d.ts") { return String(name.dropLast(5)) }
        guard let ext = ScriptLanguage.extensions.first(where: { name.hasSuffix($0) }) else { return name }
        return String(name.dropLast(ext.count))
    }

    func resolve(_ spec: String, from path: String) async throws -> String? {
        let dir = Paths.dirname(path)
        let folderOnly = Self.namesFolder(spec)
        if spec == "." || spec == ".." || spec.hasPrefix("./") || spec.hasPrefix("../") {
            return Paths.normalize(dir, spec).flatMap { file($0, folderOnly: folderOnly) }
        }
        guard !spec.hasPrefix("/") else { return nil }
        if let config = try await config(for: dir) {
            for candidate in config.candidates(for: spec) {
                if let found = file(candidate, folderOnly: folderOnly) { return found }
            }
            if let baseUrl = config.baseUrl,
               let found = Paths.normalize(baseUrl, spec).flatMap({ file($0, folderOnly: folderOnly) }) {
                return found
            }
        }
        for package in try await workspacePackages() {
            if spec == package.name { return entry(of: package) }
            if spec.hasPrefix(package.name + "/") {
                return Paths.normalize(package.dir, String(spec.dropFirst(package.name.count + 1)))
                    .flatMap { file($0, folderOnly: folderOnly) }
            }
        }
        return nil
    }

    /// A specifier whose last segment is `.` or `..`, or that ends in `/`,
    /// names a folder (as in Node and TypeScript): only its `index.*` counts,
    /// never a sibling file such as `src/api.ts` for `src/api`.
    private static func namesFolder(_ spec: String) -> Bool {
        spec.hasSuffix("/") || spec == "." || spec == ".." || spec.hasSuffix("/.") || spec.hasSuffix("/..")
    }

    /// `path` as a source file: as written, `.js` written for a `.ts` file,
    /// with an extension added, or `path/index.*`. With `folderOnly`, `path`
    /// is a folder and only `path/index.*` is tried.
    func file(_ path: String, folderOnly: Bool = false) -> String? {
        if !folderOnly {
            if ScriptLanguage.extensions.contains(where: { path.hasSuffix($0) }) && side.contains(path) {
                return path
            }
            for (js, ts) in [(".js", [".ts", ".tsx"]), (".jsx", [".tsx"]), (".mjs", [".mts"]), (".cjs", [".cts"])]
            where path.hasSuffix(js) {
                let stem = String(path.dropLast(js.count))
                if let found = ts.map({ stem + $0 }).first(where: { side.contains($0) }) { return found }
            }
            if let found = ScriptLanguage.extensions.map({ path + $0 }).first(where: { side.contains($0) }) {
                return found
            }
        }
        return ScriptLanguage.extensions.map { Paths.join(path, "index" + $0) }.first { side.contains($0) }
    }

    func entry(of package: ScriptPackage) -> String? {
        package.entries.lazy.compactMap { self.file($0) }.first
    }

    /// Every `package.json` with a name, longest name first (`@a/b-c` before `@a/b`).
    func workspacePackages() async throws -> [ScriptPackage] {
        if let packages { return packages }
        var found: [ScriptPackage] = []
        for manifest in side.sortedFiles where Paths.basename(manifest) == "package.json" {
            guard let text = try await side.text(manifest), let json = JSONC.object(text),
                  let name = json["name"] as? String, !name.isEmpty else { continue }
            let dir = Paths.dirname(manifest)
            var entries: [String] = []
            if let exports = json["exports"] as? String {
                entries.append(exports)
            } else if let exports = json["exports"] as? [String: Any], let main = exports["."] as? String {
                entries.append(main)
            }
            for key in ["module", "main"] {
                if let value = json[key] as? String { entries.append(value) }
            }
            entries += ["src/index", "index"]
            found.append(ScriptPackage(name: name, dir: dir, entries: entries.compactMap { Paths.normalize(dir, $0) }))
        }
        found.sort { ($0.name.count, $1.name) > ($1.name.count, $0.name) }
        packages = found
        return found
    }

    /// The nearest `tsconfig.json` or `jsconfig.json` at or above `dir`.
    private func config(for dir: String) async throws -> ScriptConfig? {
        if let known = configsByDir[dir] { return known }
        var result: ScriptConfig?
        if let file = ["tsconfig.json", "jsconfig.json"].map({ Paths.join(dir, $0) }).first(where: { side.contains($0) }) {
            result = try await loadConfig(file, seen: [])
        } else if !dir.isEmpty {
            result = try await config(for: Paths.dirname(dir))
        }
        configsByDir.updateValue(result, forKey: dir)
        return result
    }

    /// A config merged over its `extends` chain (relative paths only; a
    /// package name there is ignored). The child's keys win.
    private func loadConfig(_ file: String, seen: Set<String>) async throws -> ScriptConfig? {
        if let known = configsByFile[file] { return known }
        guard !seen.contains(file), let text = try await side.text(file), let json = JSONC.object(text) else {
            return nil
        }
        let dir = Paths.dirname(file)
        var merged = ScriptConfig(baseUrl: nil, pathsDir: dir)
        let parents = (json["extends"] as? [String]) ?? (json["extends"] as? String).map { [$0] } ?? []
        for parent in parents where parent.hasPrefix("./") || parent.hasPrefix("../") {
            let name = parent.hasSuffix(".json") ? parent : parent + ".json"
            guard let parentFile = Paths.normalize(dir, name),
                  let inherited = try await loadConfig(parentFile, seen: seen.union([file])) else { continue }
            if inherited.baseUrl != nil { merged.baseUrl = inherited.baseUrl }
            if !inherited.paths.isEmpty {
                merged.paths = inherited.paths
                merged.pathsDir = inherited.pathsDir
            }
        }
        let options = json["compilerOptions"] as? [String: Any] ?? [:]
        if let baseUrl = options["baseUrl"] as? String { merged.baseUrl = Paths.normalize(dir, baseUrl) }
        if let paths = options["paths"] as? [String: Any] {
            merged.paths = paths.compactMap { key, value in
                (value as? [String]).map { ScriptConfig.Alias(pattern: key, targets: $0) }
            }.sorted { $0.pattern < $1.pattern }
            merged.pathsDir = dir
        }
        configsByFile.updateValue(merged, forKey: file)
        return merged
    }
}
