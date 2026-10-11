import Foundation

/// Общая (демон + GUI) логика project-identity — перенос Sources/covey/ProjectRoot.swift.

public func pmProjectRoot(_ dir: String) -> String {
    var trimmed = dir
    while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
    if let range = trimmed.range(of: "/.worktrees/") {
        return String(trimmed[..<range.lowerBound])
    }
    if trimmed.hasSuffix("/.worktrees") {
        return trimmed.dropLast("/.worktrees".count).description
    }
    return trimmed
}

public func pmProjectDefaultName(_ root: String) -> String {
    var trimmed = root
    while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
    return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
}

public func pmSessionRoot(_ s: Session) -> String {
    guard var repo = s.worktreeRepo, !repo.isEmpty else { return pmProjectRoot(s.dir) }
    while repo.count > 1 && repo.hasSuffix("/") { repo.removeLast() }
    return repo
}

/// Longest-prefix атрибуция: побеждает самый длинный зарегистрированный корень,
/// который равен dir или является родительским каталогом (spec §6).
public enum PMAttribution {
    public static func projectRoot(for dir: String, registered: [String]) -> String? {
        let target = pmProjectRoot(dir)
        var best: String? = nil
        for raw in registered {
            let root = pmProjectRoot(raw)
            guard target == root || target.hasPrefix(root + "/") else { continue }
            if best == nil || root.count > best!.count { best = root }
        }
        return best
    }
}
