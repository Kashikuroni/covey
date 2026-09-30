import Foundation
import CoveyGit
import CoveyKit

extension ReviewModel {
    static let pollBackoff: [Double] = [3, 6, 12, 30]

    var pollDelay: Double { Self.pollBackoff[min(failureStreak, Self.pollBackoff.count - 1)] }

    /// Runs while the review is on screen (`ReviewModeView`'s `.task`, keyed by
    /// this model); while `isVisible` is false — the sessions are shown or the
    /// window is occluded — it skips checks.
    func runPolling() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(pollDelay))
            if Task.isCancelled { return }
            if isVisible { await checkFreshness() }
        }
    }

    /// Cheap check; a changed fingerprint triggers a full `reload()`. A result
    /// for a comparison the user has since left is dropped.
    func checkFreshness() async {
        guard phase == .ready, let current = state, !reloading else { return }
        let generation = loadGeneration
        do {
            let fingerprint = try await git.fingerprint(worktree: worktree, comparison: record.comparison,
                                                        paths: current.files.map(\.path))
            guard generation == loadGeneration else { return }
            // A changed fingerprint leaves the streak to `reload()`: it resets
            // it on success, so a reload that keeps failing keeps backing off.
            if fingerprint != current.fingerprint {
                await reload()
            } else {
                failureStreak = 0
                banner = nil
            }
        } catch {
            guard generation == loadGeneration else { return }
            // Removed under the review: there is nothing to retry.
            if worktreeIsGone {
                phase = .missingWorktree
                banner = nil
                return
            }
            failureStreak += 1
            banner = Self.describeLoad(error)
        }
    }

    /// The worktree's directory is no longer on disk (removed, or cleaned up
    /// with its branch).
    var worktreeIsGone: Bool { !FileManager.default.fileExists(atPath: worktree) }

    /// Re-reads the comparison in place: keeps selection, composer and
    /// scroll; refreshes the open diff without a loading flash. Every await
    /// can outlive a comparison switch (`open`); once `loadGeneration` moves
    /// the reload stops without applying or persisting anything.
    func reload() async {
        guard let old = state, !reloading else { return }
        reloading = true
        defer { reloading = false }
        let generation = loadGeneration
        do {
            let fresh = try await git.changes(worktree: worktree, comparison: record.comparison)
            guard generation == loadGeneration else { return }
            apply(fresh)
            fitCanvasIfNeeded()
            await invalidateReviewed(old: old, new: fresh)
            guard generation == loadGeneration else { return }
            if let path = selectedPath {
                if let file = file(path) {
                    await loadDiff(for: file, showLoading: false)
                } else {
                    selectedPath = nil
                    diff = .idle
                    diffOpen = false
                }
            }
            guard generation == loadGeneration else { return }
            await recheckAnchors()
            guard generation == loadGeneration else { return }
            failureStreak = 0
            banner = nil
            persist()
        } catch {
            guard generation == loadGeneration else { return }
            failureStreak += 1
            banner = Self.describeLoad(error)
        }
    }

    /// A reviewed file whose diff no longer hashes to what the reviewer saw
    /// goes back to reviewing. From a reload only files that could have
    /// changed are re-diffed: new counts/status, a moved stamp, or a moved
    /// head/base. `old == nil` (a comparison just opened) has nothing to
    /// compare against — the state may have moved while it was not loaded — so
    /// every reviewed file is treated as touched.
    ///
    /// A re-diff that fails cannot confirm the file is unchanged: a file whose
    /// counts/status changed (or with nothing to compare against) is demoted
    /// anyway; one whose stamp alone moved keeps its verdict.
    func invalidateReviewed(old: ComparisonState?, new: ComparisonState) async {
        let generation = loadGeneration
        let previous = Dictionary((old?.files ?? []).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let everythingTouched: Bool
        if let old {
            if case .ref = record.comparison.head {
                everythingTouched = old.fingerprint != new.fingerprint
            } else {
                everythingTouched = old.mergeBase != new.mergeBase
            }
        } else {
            everythingTouched = true
        }
        for file in new.files {
            guard record.files[file.path]?.state == .reviewed else { continue }
            let touched = everythingTouched || previous[file.path] != file
                || old?.stamps[file.path] != new.stamps[file.path]
            guard touched else { continue }
            // nil: the diff could not be read, but the file did change.
            let hash: String?
            if file.isBinary || (file.isUntracked && file.added == nil) {
                hash = ReviewHash.of(.empty, file: file, stamp: new.stamps[file.path])
            } else {
                let fresh = try? await git.diff(worktree: worktree, comparison: record.comparison,
                                                mergeBase: new.mergeBase, file: file, fullFile: false)
                // `record` may now belong to another comparison.
                guard generation == loadGeneration else { return }
                if let fresh {
                    hash = ReviewHash.of(fresh, file: file, stamp: new.stamps[file.path])
                } else if previous[file.path] != file {
                    hash = nil
                } else {
                    continue
                }
            }
            // Re-read: the reviewer may have changed this file during the diff.
            guard var review = record.files[file.path], review.state == .reviewed,
                  hash == nil || hash != review.reviewedDiffHash else { continue }
            review.state = .reviewing
            review.changedSinceReviewed = true
            review.reviewedDiffHash = nil
            record.files[file.path] = review
        }
    }

    /// The agent just stopped working: look for its changes now.
    func targetStatusChanged(from old: Status?, to new: Status?) async {
        guard old == .running, new != .running else { return }
        await checkFreshness()
    }
}
