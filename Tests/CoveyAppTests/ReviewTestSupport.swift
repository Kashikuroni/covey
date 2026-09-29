import Foundation
import CoveyGit
import CoveyKit
@testable import covey

struct FakeSendError: Error, CustomStringConvertible {
    var description: String { "session is gone" }
}

/// Records every write; throws `failure` (once set) instead of recording.
@MainActor
final class FakeDirectory: ReviewSessionDirectory {
    var targets: [ReviewTarget] = []
    var sent: [(name: String, bytes: [UInt8])] = []
    var failure: Error?

    func reviewTargets(projectRoot: String) -> [ReviewTarget] { targets }

    func sendToSession(_ name: String, bytes: [UInt8]) async throws {
        if let failure { throw failure }
        sent.append((name, bytes))
    }
}

/// Scripted git: every answer is a property; calls are counted.
final class FakeReviewGit: ReviewGitReading, @unchecked Sendable {
    var label: String? = "feat/x"
    var branches = ["main", "feat/x"]
    var base: String? = "main"
    /// nil → `changes` throws unknownRef for the comparison's base.
    var state: ComparisonState?
    var changesError: GitError?
    /// nil → the fingerprint of `state`.
    var fingerprintValue: String?
    var fingerprintError: GitError?
    var diffs: [String: FileDiff] = [:]
    var fullDiffs: [String: FileDiff] = [:]
    var diffError: GitError?
    private(set) var changesCalls = 0
    private(set) var fingerprintCalls = 0
    private(set) var diffCalls = 0

    func branchLabel(worktree: String) async -> String? { label }
    func localBranches(worktree: String) async -> [String] { branches }
    func defaultBase(worktree: String) async -> String? { base }

    func changes(worktree: String, comparison: GitComparison) async throws -> ComparisonState {
        changesCalls += 1
        if let changesError { throw changesError }
        guard let state else {
            throw GitError(kind: .unknownRef(comparison.base),
                           description: "unknown revision '\(comparison.base)'")
        }
        return state
    }

    func fingerprint(worktree: String, comparison: GitComparison, paths: [String]) async throws -> String {
        fingerprintCalls += 1
        if let fingerprintError { throw fingerprintError }
        return fingerprintValue ?? state?.fingerprint ?? ""
    }

    func diff(worktree: String, comparison: GitComparison, mergeBase: String,
              file: ChangedFile, fullFile: Bool) async throws -> FileDiff {
        diffCalls += 1
        if let diffError { throw diffError }
        return (fullFile ? fullDiffs[file.path] : nil) ?? diffs[file.path] ?? .empty
    }
}

func changed(_ path: String, _ status: FileStatus = .modified, added: Int? = 1, removed: Int? = 0,
             binary: Bool = false, untracked: Bool = false) -> ChangedFile {
    ChangedFile(path: path, status: status, added: added, removed: removed,
                isBinary: binary, isUntracked: untracked)
}

func comparisonState(_ files: [ChangedFile], fingerprint: String = "fp-1",
                     stamps: [String: FileStamp] = [:]) -> ComparisonState {
    ComparisonState(mergeBase: "mb", files: files, stamps: stamps, fingerprint: fingerprint)
}

/// One hunk from (kind, old number, new number, text) tuples.
func oneHunk(_ lines: [(DiffLine.Kind, Int?, Int?, String)]) -> FileDiff {
    FileDiff(hunks: [Hunk(header: "@@ -1 +1 @@", oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
                          lines: lines.map { DiffLine(kind: $0.0, oldNumber: $0.1, newNumber: $0.2, text: $0.3) })],
             isBinary: false)
}

@MainActor
func makeReviewModel(git: FakeReviewGit, directory: FakeDirectory? = nil,
                     store: ReviewStore? = nil) -> (ReviewModel, ReviewStore) {
    let store = store ?? ReviewStore(
        root: "\(NSTemporaryDirectory())covey-reviews-\(UInt32.random(in: 0..<UInt32.max))", debounce: 0)
    let model = ReviewModel(worktree: NSTemporaryDirectory(), projectRoot: "/proj", originSession: "origin",
                            git: git, store: store, directory: directory)
    model.enterDelay = .zero
    model.toastDuration = .seconds(60)
    return (model, store)
}
