import Foundation

/// A `[package]` of the repository and its crate roots.
struct RustCrate: Equatable {
    /// `name` from `[package]`, `-` → `_`.
    var name: String
    var dir: String
    var lib: String?
    /// Existing roots: lib, main, bins, tests, examples, benches.
    var roots: [String]
}

/// A module: the file it lives in plus the inline `mod x { }` path inside it.
struct RustLocation: Equatable {
    var file: String
    var inline: [String]
}

/// Crates from every `Cargo.toml`; the module tree is walked from the crate
/// roots on demand, reading only the files on the way.
final class RustResolver: ReferenceResolver {
    private struct Context {
        var root: String
        var module: [String]
    }

    /// Unowned: the side owns its resolvers (`SideIndex.resolver(for:)`), so a
    /// strong reference back would keep the side and its store alive for good.
    private unowned let side: SideIndex
    private var crates: [RustCrate]?
    private var roots: Set<String> = []
    private var libraries: [String: String] = [:]
    private var contexts: [String: Context?] = [:]

    init(side: SideIndex) {
        self.side = side
    }

    func workspace() async throws -> [RustCrate] {
        if let crates { return crates }
        var found: [RustCrate] = []
        let rustFiles = side.sortedFiles.filter { $0.hasSuffix(".rs") }
        for manifestPath in side.sortedFiles where Paths.basename(manifestPath) == "Cargo.toml" {
            guard let text = try await side.text(manifestPath) else { continue }
            let manifest = CargoManifest.parse(text)
            guard let name = manifest.packageName else { continue }
            let dir = Paths.dirname(manifestPath)
            let lib = Paths.normalize(dir, manifest.libPath ?? "src/lib.rs").flatMap { side.contains($0) ? $0 : nil }
            var candidates: [String?] = [lib, Paths.normalize(dir, "src/main.rs")]
            candidates += manifest.binPaths.map { Paths.normalize(dir, $0) }
            for file in rustFiles where Paths.contains(dir, file) {
                let rel = (dir.isEmpty ? file : String(file.dropFirst(dir.count + 1))).split(separator: "/")
                let isBin = rel.count == 3 && rel[0] == "src" && rel[1] == "bin"
                let isBinDir = rel.count == 4 && rel[0] == "src" && rel[1] == "bin" && rel[3] == "main.rs"
                let isTarget = rel.count == 2 && ["tests", "examples", "benches"].contains(rel[0])
                if isBin || isBinDir || isTarget { candidates.append(file) }
            }
            var crateRoots: [String] = []
            for case let root? in candidates where side.contains(root) && !crateRoots.contains(root) {
                crateRoots.append(root)
            }
            let crate = RustCrate(name: name.replacingOccurrences(of: "-", with: "_"), dir: dir,
                                  lib: lib, roots: crateRoots)
            found.append(crate)
            if let lib, libraries[crate.name] == nil { libraries[crate.name] = lib }
        }
        crates = found
        roots = Set(found.flatMap(\.roots))
        return found
    }

    func resolve(_ source: ParsedSource, from path: String) async throws -> [Resolution?] {
        guard let syntax = source.syntax as? RustSyntax else { return [] }
        _ = try await workspace()
        let context = try await context(of: path)
        var resolved: [Resolution?] = []
        for ref in syntax.paths {
            resolved.append(try await resolve(ref, in: context))
        }
        return resolved
    }

    /// The crate name for a crate root, else the module name (`foo` for
    /// `foo.rs` and `foo/mod.rs`).
    func keywords(for path: String) async throws -> [String] {
        let crates = try await workspace()
        if roots.contains(path) {
            return crates.filter { $0.roots.contains(path) }.map(\.name)
        }
        let name = Paths.basename(path)
        guard name.hasSuffix(".rs") else { return [] }
        if name == "mod.rs" {
            let folder = Paths.basename(Paths.dirname(path))
            return folder.isEmpty ? [] : [folder]
        }
        return [String(name.dropLast(3))]
    }

    // MARK: - resolution

    /// Walks the path from where its first segment points, while the next
    /// segment is a module; the file reached is the target and the segment
    /// that stopped the walk is the name.
    private func resolve(_ ref: RustSyntax.PathRef, in context: Context?) async throws -> Resolution? {
        guard let first = ref.segments.first else { return nil }
        var rest = ref.segments.dropFirst()
        var location: RustLocation
        var depth = 0
        if ref.global {
            guard let lib = libraries[first] else { return nil }
            location = RustLocation(file: lib, inline: [])
        } else if first == "crate" {
            guard let context else { return nil }
            location = RustLocation(file: context.root, inline: [])
        } else if first == "self" || first == "super" {
            guard let context else { return nil }
            var module = context.module + ref.scope
            if first == "super" {
                rest = ref.segments[...]
                while rest.first == "super" {
                    guard !module.isEmpty else { return nil }
                    module.removeLast()
                    rest = rest.dropFirst()
                }
            }
            guard let here = try await walk(from: context.root, module) else { return nil }
            location = here
        } else if ref.isUse, let context,
                  let here = try await walk(from: context.root, context.module + ref.scope),
                  let child = try await step(here, first) {
            location = child
            depth = 1
        } else if let lib = libraries[first] {
            location = RustLocation(file: lib, inline: [])
        } else {
            return nil
        }
        var names: [String] = []
        for segment in rest {
            if segment == "*" {
                names = ["*"]
                break
            }
            guard let next = try await step(location, segment) else {
                names = [segment]
                break
            }
            location = next
            depth += 1
        }
        return Resolution(target: location.file, names: names, depth: depth)
    }

    /// Which crate root reaches `path`, and by which module path. A renamed
    /// file on the base side is looked up at its former path.
    private func context(of path: String) async throws -> Context? {
        if let known = contexts[path] { return known }
        var result: Context?
        if !side.contains(path), let former = side.formerPaths[path] {
            result = try await context(of: former)
        } else if let crate = try await workspace().filter({ Paths.contains($0.dir, path) })
                    .max(by: { $0.dir.count < $1.dir.count }) {
            if crate.roots.contains(path) {
                result = Context(root: path, module: [])
            } else {
                for root in crate.roots {
                    let rootDir = Paths.dirname(root)
                    guard Paths.contains(rootDir, path),
                          let module = Self.modulePath(of: path, under: rootDir),
                          let reached = try await walk(from: root, module),
                          reached == RustLocation(file: path, inline: []) else { continue }
                    result = Context(root: root, module: module)
                    break
                }
            }
        }
        contexts.updateValue(result, forKey: path)
        return result
    }

    /// `src/net/client.rs` under `src` → [net, client]; `src/net/mod.rs` → [net].
    static func modulePath(of path: String, under dir: String) -> [String]? {
        let rel = dir.isEmpty ? path : String(path.dropFirst(dir.count + 1))
        var parts = rel.split(separator: "/").map(String.init)
        guard let last = parts.popLast(), last.hasSuffix(".rs") else { return nil }
        if last != "mod.rs" { parts.append(String(last.dropLast(3))) }
        return parts
    }

    private func walk(from root: String, _ module: [String]) async throws -> RustLocation? {
        var location = RustLocation(file: root, inline: [])
        for segment in module {
            guard let next = try await step(location, segment) else { return nil }
            location = next
        }
        return location
    }

    /// The child module `segment`, when the parent declares it and, for
    /// `mod x;`, `x.rs` or `x/mod.rs` exists.
    private func step(_ location: RustLocation, _ segment: String) async throws -> RustLocation? {
        guard let syntax = try await side.parsed(location.file)?.syntax as? RustSyntax else { return nil }
        let path = location.inline + [segment]
        guard let module = syntax.modules.first(where: { $0.path == path }) else { return nil }
        if module.inline { return RustLocation(file: location.file, inline: path) }
        let stem = Paths.join(moduleFolder(of: location.file), path.joined(separator: "/"))
        for candidate in [stem + ".rs", stem + "/mod.rs"] where side.contains(candidate) {
            return RustLocation(file: candidate, inline: [])
        }
        return nil
    }

    /// Where `mod x;` looks for `x`: the file's own folder for crate roots,
    /// `lib.rs`, `main.rs` and `mod.rs`; `foo/` for `foo.rs`.
    private func moduleFolder(of file: String) -> String {
        let name = Paths.basename(file)
        if roots.contains(file) || name == "lib.rs" || name == "main.rs" || name == "mod.rs" {
            return Paths.dirname(file)
        }
        return Paths.join(Paths.dirname(file), String(name.dropLast(3)))
    }
}
