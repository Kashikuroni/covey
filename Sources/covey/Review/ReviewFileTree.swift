import Foundation
import CoveyGit

struct FileFilter: Equatable {
    var query = ""
    var statuses: Set<FileStatus> = Set(FileStatus.allCases)
    var unreviewedOnly = false
    var withIssuesOnly = false
    var changedOnly = false
}

struct FileTreeRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case directory(path: String, expanded: Bool)
        case file(ChangedFile)
    }

    let id: String
    let name: String
    let depth: Int
    let kind: Kind
}

enum ReviewGlyph: Equatable {
    case unread, reviewing, reviewed, issues

    static func of(_ review: FileReview, hasOpenIssues: Bool) -> ReviewGlyph {
        if hasOpenIssues { return .issues }
        switch review.state {
        case .unread: return .unread
        case .reviewing: return .reviewing
        case .reviewed: return .reviewed
        }
    }

    var symbol: String {
        switch self {
        case .unread: return "○"
        case .reviewing: return "◐"
        case .reviewed: return "✓"
        case .issues: return "!"
        }
    }
}

enum ReviewFileTree {
    /// Tree order: at every level directories come before files, then by name.
    static func precedes(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: "/").map(String.init)
        let y = b.split(separator: "/").map(String.init)
        for i in 0..<min(x.count, y.count) where x[i] != y[i] {
            let xIsDir = i < x.count - 1
            let yIsDir = i < y.count - 1
            if xIsDir != yIsDir { return xIsDir }
            return x[i] < y[i]
        }
        return x.count < y.count
    }

    static func sorted(_ files: [ChangedFile]) -> [ChangedFile] {
        files.sorted { precedes($0.path, $1.path) }
    }

    /// Directory rows are emitted once, before their first file; everything
    /// under a collapsed directory is hidden (the directory row itself stays).
    static func rows(_ files: [ChangedFile], collapsed: Set<String>) -> [FileTreeRow] {
        var rows: [FileTreeRow] = []
        var emitted: Set<String> = []
        for file in sorted(files) {
            let parts = file.path.split(separator: "/").map(String.init)
            var hidden = false
            for depth in 0..<max(parts.count - 1, 0) {
                let dir = parts[0...depth].joined(separator: "/")
                if emitted.insert(dir).inserted, !hidden {
                    rows.append(FileTreeRow(id: "d:\(dir)", name: parts[depth], depth: depth,
                                            kind: .directory(path: dir, expanded: !collapsed.contains(dir))))
                }
                if collapsed.contains(dir) { hidden = true }
            }
            if !hidden {
                rows.append(FileTreeRow(id: "f:\(file.path)", name: parts.last ?? file.path,
                                        depth: max(parts.count - 1, 0), kind: .file(file)))
            }
        }
        return rows
    }

    static func matches(_ file: ChangedFile, filter: FileFilter, review: FileReview,
                        hasOpenIssues: Bool) -> Bool {
        let query = filter.query.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty, !file.path.localizedCaseInsensitiveContains(query) { return false }
        guard filter.statuses.contains(file.status) else { return false }
        if filter.unreviewedOnly, review.state == .reviewed { return false }
        if filter.withIssuesOnly, !hasOpenIssues { return false }
        if filter.changedOnly, !review.changedSinceReviewed { return false }
        return true
    }
}
