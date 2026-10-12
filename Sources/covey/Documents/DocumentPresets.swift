import Foundation
import CoveyKit
import Darwin

enum DocumentPresets {
    static let rules: [DocumentPresetID: [String]] = [
        .swift: [".build/", ".swiftpm/", "DerivedData/", "build/", "xcuserdata/", "*.xcuserstate", "*.xcuserdatad/"],
        .common: [".git/", ".hg/", ".svn/"], .rust: ["target/"],
        .node: ["node_modules/", ".npm/", ".pnpm-store/", "**/.yarn/cache/", "**/.yarn/unplugged/", ".turbo/", ".parcel-cache/"],
        .react: [], .vue: [], .next: [".next/"], .nuxt: [".nuxt/", ".output/"],
        .python: [".venv/", "venv/", "__pycache__/", ".pytest_cache/", ".mypy_cache/", ".ruff_cache/", ".tox/", ".nox/", ".eggs/", "__pypackages__/"],
    ]
    static let optionalRules = ["dist/", "build/", "out/", "coverage/", "htmlcov/", "storybook-static/"]
    static func detect(directory: URL, context: DocumentContext? = nil) -> Set<DocumentPresetID> {
        let context = context ?? DocumentContext(sourceSession:"",root:directory.path,projectKey:directory.path)
        func relative(_ name: String) -> String? { try? DocumentLinkResolver.relativePath(url:directory.appendingPathComponent(name),context:context) }
        func exists(_ name: String) -> Bool {
            guard let path = relative(name), let url = try? DocumentLinkResolver.fileURL(path:path,context:context) else { return false }
            return (try? url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true
        }
        var found: Set<DocumentPresetID> = [.common]
        let children = (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isDirectoryKey])) ?? []
        if exists("Package.swift") || children.contains(where: {
            ["xcodeproj","xcworkspace"].contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true
        }) { found.insert(.swift) }
        if exists("Cargo.toml") { found.insert(.rust) }
        if ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt"].contains(where: exists) { found.insert(.python) }
        if exists("package.json") {
            found.insert(.node)
            if let path = relative("package.json"), let data = manifestData(path:path,context:context),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let deps = Set(((obj["dependencies"] as? [String: Any]) ?? [:]).keys).union(((obj["devDependencies"] as? [String: Any]) ?? [:]).keys)
                if deps.contains("react") { found.insert(.react) }
                if deps.contains("vue") { found.insert(.vue) }
                if deps.contains("next") { found.formUnion([.react, .next]) }
                if deps.contains("nuxt") { found.formUnion([.vue, .nuxt]) }
            }
        }
        return found
    }
    private static func manifestData(path: String, context: DocumentContext) -> Data? {
        guard let fd = try? DocumentLinkResolver.openRegularFile(path:path,context:context) else { return nil }
        defer { Darwin.close(fd) }
        let limit = 1_048_576
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_size <= limit else { return nil }
        var data = Data(), buffer = [UInt8](repeating:0,count:65536)
        while data.count <= limit {
            guard !Task.isCancelled else { return nil }
            let wanted = min(buffer.count,limit+1-data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd,$0.baseAddress,wanted) }
            if count < 0 { if errno == EINTR { continue }; return nil }
            if count == 0 { return data }
            data.append(contentsOf:buffer.prefix(count))
        }
        return nil
    }
    static func title(_ preset: DocumentPresetID) -> String {
        switch preset { case .swift: return "Swift / Xcode"; case .node: return "Node / TypeScript"; case .common: return "Version control"; default: return preset.rawValue.capitalized }
    }
    static func description(_ pattern: String) -> String {
        switch pattern {
        case ".build/": return "SwiftPM build products and debug files"
        case ".swiftpm/": return "SwiftPM workspace state"
        case "DerivedData/": return "Xcode build products, indexes and caches"
        case "build/": return "Build output"
        case "xcuserdata/", "*.xcuserdatad/", "*.xcuserstate": return "Xcode user settings and debugger state"
        case "target/": return "Rust build output"
        case "node_modules/": return "Installed Node dependencies"
        case ".venv/", "venv/": return "Python virtual environment"
        case ".git/", ".hg/", ".svn/": return "Version-control internals"
        default: return "Generated files or caches; matching folders include all contents"
        }
    }
}
