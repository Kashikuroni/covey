import Foundation
import CoveyKit

enum DocumentPresets {
    static let rules: [DocumentPresetID: [String]] = [
        .common: [".git/", ".hg/", ".svn/"], .rust: ["target/"],
        .node: ["node_modules/", ".npm/", ".pnpm-store/", "**/.yarn/cache/", "**/.yarn/unplugged/", ".turbo/", ".parcel-cache/"],
        .react: [], .vue: [], .next: [".next/"], .nuxt: [".nuxt/", ".output/"],
        .python: [".venv/", "venv/", "__pycache__/", ".pytest_cache/", ".mypy_cache/", ".ruff_cache/", ".tox/", ".nox/", ".eggs/", "__pypackages__/"],
    ]
    static let optionalRules = ["dist/", "build/", "out/", "coverage/", "htmlcov/", "storybook-static/"]
    static func detect(directory: URL) -> Set<DocumentPresetID> {
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) }
        var found: Set<DocumentPresetID> = [.common]
        if exists("Cargo.toml") { found.insert(.rust) }
        if ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt"].contains(where: exists) { found.insert(.python) }
        if exists("package.json") {
            found.insert(.node)
            let url = directory.appendingPathComponent("package.json")
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
               let data = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let deps = Set(((obj["dependencies"] as? [String: Any]) ?? [:]).keys).union(((obj["devDependencies"] as? [String: Any]) ?? [:]).keys)
                if deps.contains("react") { found.insert(.react) }
                if deps.contains("vue") { found.insert(.vue) }
                if deps.contains("next") { found.formUnion([.react, .next]) }
                if deps.contains("nuxt") { found.formUnion([.vue, .nuxt]) }
            }
        }
        return found
    }
}
