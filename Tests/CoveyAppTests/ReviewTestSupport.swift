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
    /// Per-base answers for `changes`; a base not listed falls back to `state`.
    var statesByBase: [String: ComparisonState] = [:]

    // Calls run off the main thread and, with a gate held, can overlap, so
    // the counters and the gate tables sit behind a lock.
    private let lock = NSLock()
    private var _changesCalls = 0
    private var _fingerprintCalls = 0
    private var _fingerprintWorktrees: [String] = []
    private var _diffCalls = 0
    private var changesGates: [String: CallGate] = [:]
    private var diffGates: [Bool: CallGate] = [:]

    var changesCalls: Int { lock.withLock { _changesCalls } }
    var fingerprintCalls: Int { lock.withLock { _fingerprintCalls } }
    /// The worktree of every `fingerprint` call, in order: who is polling.
    var fingerprintWorktrees: [String] { lock.withLock { _fingerprintWorktrees } }
    var diffCalls: Int { lock.withLock { _diffCalls } }

    /// The next `changes` call for `base` parks until the gate is released.
    func holdNextChanges(base: String) -> CallGate {
        let gate = CallGate()
        lock.withLock { changesGates[base] = gate }
        return gate
    }

    /// The next `diff` call with this `fullFile` value parks until released.
    func holdNextDiff(fullFile: Bool) -> CallGate {
        let gate = CallGate()
        lock.withLock { diffGates[fullFile] = gate }
        return gate
    }

    func branchLabel(worktree: String) async -> String? { label }
    func localBranches(worktree: String) async -> [String] { branches }
    func defaultBase(worktree: String) async -> String? { base }

    func changes(worktree: String, comparison: GitComparison) async throws -> ComparisonState {
        let gate: CallGate? = lock.withLock {
            _changesCalls += 1
            return changesGates.removeValue(forKey: comparison.base)
        }
        if let gate { try await gate.hold() }
        if let changesError { throw changesError }
        guard let answer = statesByBase[comparison.base] ?? state else {
            throw GitError(kind: .unknownRef(comparison.base),
                           description: "unknown revision '\(comparison.base)'")
        }
        return answer
    }

    func fingerprint(worktree: String, comparison: GitComparison, paths: [String]) async throws -> String {
        lock.withLock {
            _fingerprintCalls += 1
            _fingerprintWorktrees.append(worktree)
        }
        if let fingerprintError { throw fingerprintError }
        return fingerprintValue ?? state?.fingerprint ?? ""
    }

    func diff(worktree: String, comparison: GitComparison, mergeBase: String,
              file: ChangedFile, fullFile: Bool) async throws -> FileDiff {
        let gate: CallGate? = lock.withLock {
            _diffCalls += 1
            return diffGates.removeValue(forKey: fullFile)
        }
        if let gate { try await gate.hold() }
        if let diffError { throw diffError }
        return (fullFile ? fullDiffs[file.path] : nil) ?? diffs[file.path] ?? .empty
    }
}

/// Parks one fake git call until the test releases it, so a test can
/// interleave two operations deterministically: wait for the call to arrive,
/// do something else, then release it (optionally with an error).
final class CallGate: @unchecked Sendable {
    private let lock = NSLock()
    private var arrived = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var held: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?

    /// Called by the fake: returns (or throws) once `release` has run.
    func hold() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            arrived = true
            let waiters = arrivalWaiters
            arrivalWaiters = []
            let settled = outcome
            if settled == nil { held = continuation }
            lock.unlock()
            if let settled { continuation.resume(with: settled) }
            waiters.forEach { $0.resume() }
        }
    }

    /// Suspends until the held call has reached the gate.
    func waitUntilArrived() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if arrived {
                lock.unlock()
                continuation.resume()
            } else {
                arrivalWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release(throwing error: Error? = nil) {
        let result: Result<Void, Error>
        if let error { result = .failure(error) } else { result = .success(()) }
        lock.lock()
        outcome = result
        let continuation = held
        held = nil
        lock.unlock()
        continuation?.resume(with: result)
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
