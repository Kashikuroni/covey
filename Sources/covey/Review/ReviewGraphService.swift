import Foundation
import CoveyGit
import CoveyCodeGraph

/// Builds a comparison's link graph and reads head files for the graph's
/// read-only view. `ReviewGraphService` is the real one; tests script a fake.
protocol ReviewGraphBuilding: Sendable {
    func build(worktree: String, comparison: GitComparison, state: ComparisonState) async -> LinkGraph
    /// `path` as it is at the comparison's head; nil when it cannot be shown
    /// (missing, binary, not UTF-8, over 1 MB).
    func headText(worktree: String, comparison: GitComparison, path: String) async -> String?
}

/// One per review model: its `LinkGraphBuilder` keeps the parse cache
/// between rebuilds (spec: the cache lives with the review model).
struct ReviewGraphService: ReviewGraphBuilding {
    let builder = LinkGraphBuilder()

    func build(worktree: String, comparison: GitComparison, state: ComparisonState) async -> LinkGraph {
        let changes = ReviewGraphInput.changes(state.files)
        let head: GitSourceProvider.Head
        do {
            head = try await Self.head(of: comparison, worktree: worktree)
        } catch {
            return .unavailable("\(error)")
        }
        let provider = GitSourceProvider(root: worktree, base: state.mergeBase, head: head,
                                         goneAtHead: ReviewGraphInput.goneAtHead(changes))
        return await builder.build(changes: changes, provider: provider)
    }

    func headText(worktree: String, comparison: GitComparison, path: String) async -> String? {
        guard let head = try? await Self.head(of: comparison, worktree: worktree) else { return nil }
        let provider = GitSourceProvider(root: worktree, base: "", head: head, goneAtHead: [])
        return (try? await provider.text(path, .head)) ?? nil
    }

    /// The compared commit, resolved once per build so a branch that moves
    /// meanwhile cannot mix two heads into one graph.
    static func head(of comparison: GitComparison, worktree: String) async throws -> GitSourceProvider.Head {
        guard case .ref(let ref) = comparison.head else { return .workingTree }
        guard let commit = await offMain({ Repository(at: worktree).resolveCommit(ref) }) else {
            throw GitError(kind: .unknownRef(ref), description: "unknown revision '\(ref)'")
        }
        return .commit(commit)
    }
}
