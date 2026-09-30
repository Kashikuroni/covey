import Foundation

/// The three `Cargo.toml` keys the graph needs, read line by line — not a
/// TOML parser: `[package] name`, `[lib] path` and every `[[bin]] path`.
struct CargoManifest: Equatable {
    var packageName: String?
    var libPath: String?
    var binPaths: [String] = []

    static func parse(_ text: String) -> CargoManifest {
        var manifest = CargoManifest()
        var table = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                table = line.replacingOccurrences(of: "[", with: "")
                    .components(separatedBy: "]")[0].trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = stringValue(line[line.index(after: equals)...])
            switch (table, key) {
            case ("package", "name"): manifest.packageName = value
            case ("lib", "path"): manifest.libPath = value
            case ("bin", "path"): if let value { manifest.binPaths.append(value) }
            default: break
            }
        }
        return manifest
    }

    /// A basic `"…"` or literal `'…'` string; nil for anything else.
    private static func stringValue(_ raw: Substring) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard let quote = value.first, quote == "\"" || quote == "'" else { return nil }
        let rest = value.dropFirst()
        guard let end = rest.firstIndex(of: quote) else { return nil }
        return String(rest[..<end])
    }
}
