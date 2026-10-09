import Foundation
import CoveyGit

/// The only place that writes the repository (umbrella invariant 1):
/// stage/unstage, commit, push — always via ReviewGitReading (→ CoveyGit).
extension ReviewModel {
    var stagedPaths: [String] {
        files.filter { indexState[$0.path] == true }.map(\.path).sorted()
    }

    var hasStaged: Bool { !stagedPaths.isEmpty }

    func refreshIndex() async {
        guard phase == .ready else { return }
        let generation = loadGeneration
        let entries = (try? await git.indexStatus(worktree: worktree)) ?? []
        guard generation == loadGeneration else { return }
        // A path can appear twice (staged deletion + untracked file on disk);
        // porcelain lists changed entries first — keep the first (staged) one.
        indexState = Dictionary(entries.map { ($0.path, $0.staged) },
                                uniquingKeysWith: { first, _ in first })
    }

    func refreshUpstream() async {
        guard phase == .ready else { return }
        let generation = loadGeneration
        let info = await git.upstreamInfo(worktree: worktree)
        guard generation == loadGeneration else { return }
        upstream = info
        if info != nil { pushUpstreamPending = false }
    }

    /// Re-checks the fingerprint; reloads and reports when the tree moved
    /// under us (Review Focus 1 — no op ever runs on a stale snapshot).
    /// Returns false when there is no loaded comparison to verify against.
    func ensureFresh() async -> Bool {
        guard let current = state else { return false }
        let fingerprint = try? await git.fingerprint(
            worktree: worktree, comparison: record.comparison, paths: current.files.map(\.path))
        if fingerprint != current.fingerprint {
            await reload()
            banner = "Tree changed — refreshed before staging"
        }
        return true
    }

    /// Stage/unstage one path. Refresh-checks the fingerprint first.
    func setStaged(_ path: String, _ staged: Bool) async {
        guard phase == .ready, await ensureFresh() else { return }
        guard state?.files.contains(where: { $0.path == path }) == true else { return }
        do {
            if staged { try await git.stage(worktree: worktree, paths: [path]) }
            else { try await git.unstage(worktree: worktree, paths: [path]) }
        } catch {
            banner = String(describing: error)
            toast(String(describing: error))
            return
        }
        await refreshIndex()
    }

    func toggleStagedFocused() async {
        guard let path = selectedPath else { return }
        await setStaged(path, indexState[path] != true)
    }

    func stageAllChanges() async {
        do { try await git.stageAll(worktree: worktree) }
        catch {
            banner = String(describing: error)
            toast(String(describing: error))
            return
        }
        await refreshIndex()
    }

    func unstageAllChanges() async {
        do { try await git.unstageAll(worktree: worktree) }
        catch {
            banner = String(describing: error)
            toast(String(describing: error))
            return
        }
        await refreshIndex()
    }

    func beginCommit() {
        guard hasStaged else { return }
        commitError = nil
        commitSheetOpen = true
    }

    /// Sheet-side enablement for the Commit button.
    func canCommit(_ summary: String) -> Bool {
        hasStaged && !committing && !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func cancelCommit() {
        commitSheetOpen = false
        commitError = nil
    }

    func commit(summary: String, body: String) async {
        guard canCommit(summary) else { return }
        guard await ensureFresh(), hasStaged else { return }   // tree may have moved; re-derive
        committing = true
        defer { committing = false }
        do {
            _ = try await git.commit(worktree: worktree, summary: summary,
                                     body: body, amend: false)
            cancelCommit()
            await reload()
            toast("Committed")
        } catch {
            commitError = String(describing: error)
        }
    }

    /// Pushes the picked worktree's branch. Without upstream, the first click
    /// arms the publish action; the second publishes with `-u origin`.
    func push() async {
        guard phase == .ready, !pushing else { return }
        let message: String
        do {
            if let upstream {
                pushing = true
                defer { pushing = false }
                try await git.push(worktree: worktree, remote: upstream.remote, setUpstream: false)
                try? await git.fetch(worktree: worktree, remote: upstream.remote)
                message = "Pushed"
            } else {
                guard pushUpstreamPending else {
                    pushUpstreamPending = true
                    toast("No upstream — click again to publish \(branchLabel) as origin/\(branchLabel)")
                    return
                }
                pushUpstreamPending = false
                pushing = true
                defer { pushing = false }
                try await git.push(worktree: worktree, remote: "origin", setUpstream: true)
                try? await git.fetch(worktree: worktree, remote: "origin")
                message = "Pushed · published origin/\(branchLabel)"
            }
        } catch {
            banner = String(describing: error)
            toast(String(describing: error))
            return
        }
        await refreshUpstream()
        await reload()
        toast(message)
    }
}
