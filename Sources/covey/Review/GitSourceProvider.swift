import Foundation
import CoveyGit
import CoveyCodeGraph

/// The Review graph's files (spec part 2, «Реализация в приложении»): base
/// is the comparison's merge base, head the working tree or the compared
/// commit. Every read runs off the main thread (`offMain`).
struct GitSourceProvider: SourceProvider {
    enum Head: Hashable, Sendable {
        case workingTree
        case commit(String)
    }

    /// The worktree toplevel.
    let root: String
    /// The merge-base commit.
    let base: String
    let head: Head
    /// Paths the change removed at head (deletions, rename sources). The
    /// working-tree listing still names an unstaged deletion — the index has
    /// it — so they are taken out of it.
    let goneAtHead: Set<String>
    var maxBytes = GraphLimits.standard.maxFileBytes

    func files(_ side: SourceSide) async throws -> [String] {
        let repo = Repository(at: root)
        switch (side, head) {
        case (.base, _):
            let base = base
            return try await offMainThrowing { try repo.files(at: base) }
        case (.head, .commit(let commit)):
            return try await offMainThrowing { try repo.files(at: commit) }
        case (.head, .workingTree):
            let gone = goneAtHead
            return try await offMainThrowing { try repo.workingTreeFiles().filter { !gone.contains($0) } }
        }
    }

    func text(_ path: String, _ side: SourceSide) async throws -> String? {
        let repo = Repository(at: root)
        let limit = maxBytes
        let revision: String
        switch (side, head) {
        case (.base, _): revision = base
        case (.head, .commit(let commit)): revision = commit
        case (.head, .workingTree):
            let full = (root as NSString).appendingPathComponent(path)
            return await offMain { Self.readFile(full, maxBytes: limit) }
        }
        return try await offMainThrowing {
            try repo.blob(path, at: revision, maxBytes: limit).flatMap { Self.decode($0, maxBytes: limit) }
        }
    }

    func filesMentioning(_ words: [String]) async throws -> [String] {
        let repo = Repository(at: root)
        var revision: String?
        if case .commit(let commit) = head { revision = commit }
        let at = revision
        return try await offMainThrowing { try repo.filesMentioning(words, at: at) }
    }

    /// A file on disk as text; nil unless it is a regular file (a symlink is
    /// not followed) within `maxBytes` that `decode` accepts.
    static func readFile(_ fullPath: String, maxBytes: Int) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fullPath),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= maxBytes,
              let data = FileManager.default.contents(atPath: fullPath) else { return nil }
        return decode(data, maxBytes: maxBytes)
    }

    /// UTF-8 text, or nil for binary (a NUL byte), non-UTF-8 or oversized data.
    static func decode(_ data: Data, maxBytes: Int) -> String? {
        guard data.count <= maxBytes, !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// `CoveyGit`'s change list in the graph builder's terms (spec part 2: the
/// app translates `ChangedFile`).
enum ReviewGraphInput {
    static func changes(_ files: [ChangedFile]) -> [ChangedSource] {
        files.map { file in
            switch file.status {
            case .added: return ChangedSource(path: file.path, change: .added)
            case .modified: return ChangedSource(path: file.path, change: .modified)
            case .deleted: return ChangedSource(path: file.path, change: .deleted)
            case .renamed:
                // git always names the old path; without one there is no base side.
                guard let old = file.oldPath else { return ChangedSource(path: file.path, change: .added) }
                return ChangedSource(path: file.path, change: .renamed(from: old))
            }
        }
    }

    /// Deleted paths and rename sources, unless the change has a file there
    /// again at head.
    static func goneAtHead(_ changes: [ChangedSource]) -> Set<String> {
        var gone = Set<String>()
        for change in changes {
            switch change.change {
            case .deleted: gone.insert(change.path)
            case .renamed(let from): gone.insert(from)
            case .added, .modified: break
            }
        }
        return gone.subtracting(changes.compactMap(\.headPath))
    }
}
