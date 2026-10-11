import Foundation
import CoveyGit
import CoveyKit
import CoveyCodeGraph
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
    /// Every session a whole review reached.
    var delivered: [String] = []

    func reviewTargets(projectRoot: String) -> [ReviewTarget] { targets }

    func sendToSession(_ name: String, bytes: [UInt8]) async throws {
        if let failure { throw failure }
        sent.append((name, bytes))
    }

    func didSendReview(to name: String) {
        delivered.append(name)
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
    private var _fingerprintGates: [CallGate] = []

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

    /// The next `fingerprint` call parks until the gate is released.
    func holdNextFingerprint() -> CallGate {
        let gate = CallGate()
        lock.withLock { _fingerprintGates.append(gate) }
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
        let gate: CallGate? = lock.withLock {
            _fingerprintCalls += 1
            _fingerprintWorktrees.append(worktree)
            return _fingerprintGates.isEmpty ? nil : _fingerprintGates.removeFirst()
        }
        if let gate { try await gate.hold() }
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

    // MARK: Ops surface (scripted answers + recorded calls)

    var indexEntries: [IndexEntry] = []
    var upstream: UpstreamInfo?
    var commitError: Error?
    var pushError: Error?
    var commitOID = "feed0001"

    private let opsLock = NSLock()
    private var _stageCalls: [[String]] = []
    private var _unstageCalls: [[String]] = []
    private var _stageAllCalls = 0
    private var _unstageAllCalls = 0
    private var _commitCalls: [(summary: String, body: String, amend: Bool)] = []
    private var _pushCalls: [(remote: String, setUpstream: Bool)] = []
    private var _fetchCalls: [String] = []

    var stageCalls: [[String]] { opsLock.withLock { _stageCalls } }
    var unstageCalls: [[String]] { opsLock.withLock { _unstageCalls } }
    var stageAllCalls: Int { opsLock.withLock { _stageAllCalls } }
    var unstageAllCalls: Int { opsLock.withLock { _unstageAllCalls } }
    var commitCalls: [(summary: String, body: String, amend: Bool)] { opsLock.withLock { _commitCalls } }
    var pushCalls: [(remote: String, setUpstream: Bool)] { opsLock.withLock { _pushCalls } }
    var fetchCalls: [String] { opsLock.withLock { _fetchCalls } }

    func indexStatus(worktree: String) async throws -> [IndexEntry] { indexEntries }

    func upstreamInfo(worktree: String) async -> UpstreamInfo? { upstream }

    func stage(worktree: String, paths: [String]) async throws {
        opsLock.withLock { _stageCalls.append(paths) }
        for path in paths {
            indexEntries.removeAll { $0.path == path }
            indexEntries.append(IndexEntry(path: path, staged: true, isUntracked: false))
        }
    }

    func stageAll(worktree: String) async throws {
        opsLock.withLock { _stageAllCalls += 1 }
        indexEntries = indexEntries.map {
            IndexEntry(path: $0.path, staged: true, isUntracked: $0.isUntracked)
        }
    }

    func unstage(worktree: String, paths: [String]) async throws {
        opsLock.withLock { _unstageCalls.append(paths) }
        for path in paths {
            indexEntries.removeAll { $0.path == path }
            indexEntries.append(IndexEntry(path: path, staged: false, isUntracked: false))
        }
    }

    func unstageAll(worktree: String) async throws {
        opsLock.withLock { _unstageAllCalls += 1 }
        indexEntries = indexEntries.map {
            IndexEntry(path: $0.path, staged: false, isUntracked: $0.isUntracked)
        }
    }

    func commit(worktree: String, summary: String, body: String, amend: Bool) async throws -> String {
        opsLock.withLock { _commitCalls.append((summary, body, amend)) }
        if let commitError { throw commitError }
        return commitOID
    }

    func push(worktree: String, remote: String, setUpstream: Bool) async throws {
        opsLock.withLock { _pushCalls.append((remote, setUpstream)) }
        if let pushError { throw pushError }
        if !setUpstream { upstream?.ahead = 0 }
    }

    func fetch(worktree: String, remote: String) async throws {
        opsLock.withLock { _fetchCalls.append(remote) }
    }

    // MARK: Management surface (phase 2, scripted answers + recorded calls)

    var worktreeEntries: [WorktreeListEntry] = []
    var mergedInto: [String] = []
    var lastCommitStamps: [String: Int64] = [:]
    var aheadBehindByBranch: [String: (ahead: Int, behind: Int)] = [:]
    var summaries: [String: WorkingTreeSummary] = [:]
    var opsError: Error?

    private var _worktreeAddCalls: [(path: String, newBranch: String, base: String)] = []
    private var _removeCalls: [String] = []
    private var _promoteCalls: [(path: String, branch: String)] = []
    private var _checkoutCalls: [(worktree: String, branch: String)] = []
    private var _branchDeleteCalls: [(branch: String, protected: [String])] = []
    private var _updateFromBaseCalls: [(worktree: String, base: String)] = []

    var worktreeAddCalls: [(path: String, newBranch: String, base: String)] {
        opsLock.withLock { _worktreeAddCalls }
    }
    var removeCalls: [String] { opsLock.withLock { _removeCalls } }
    var promoteCalls: [(path: String, branch: String)] { opsLock.withLock { _promoteCalls } }
    var checkoutCalls: [(worktree: String, branch: String)] { opsLock.withLock { _checkoutCalls } }
    var branchDeleteCalls: [(branch: String, protected: [String])] {
        opsLock.withLock { _branchDeleteCalls }
    }
    var updateFromBaseCalls: [(worktree: String, base: String)] {
        opsLock.withLock { _updateFromBaseCalls }
    }

    func worktreeList(root: String) async throws -> [WorktreeListEntry] { worktreeEntries }
    func mergedBranches(root: String, into base: String) async throws -> [String] { mergedInto }
    func lastCommit(worktree: String) async -> Int64? { lastCommitStamps[worktree] }
    func aheadBehind(root: String, branch: String, base: String) async -> (ahead: Int, behind: Int) {
        aheadBehindByBranch[branch] ?? (0, 0)
    }
    func summary(worktree: String) async -> WorkingTreeSummary? { summaries[worktree] }
    func addWorktree(root: String, path: String, newBranch: String, base: String) async throws {
        opsLock.withLock { _worktreeAddCalls.append((path, newBranch, base)) }
        if let opsError { throw opsError }
    }
    func removeWorktree(path: String) async throws {
        opsLock.withLock { _removeCalls.append(path) }
        if let opsError { throw opsError }
    }
    func promoteWorktree(path: String, branch: String) async throws {
        opsLock.withLock { _promoteCalls.append((path, branch)) }
        if let opsError { throw opsError }
    }
    func checkout(worktree: String, branch: String) async throws {
        opsLock.withLock { _checkoutCalls.append((worktree, branch)) }
        if let opsError { throw opsError }
    }
    func deleteBranch(worktree: String, branch: String, protected: [String]) async throws {
        opsLock.withLock { _branchDeleteCalls.append((branch, protected)) }
        if let opsError { throw opsError }
    }
    func updateFromBase(worktree: String, base: String) async throws {
        opsLock.withLock { _updateFromBaseCalls.append((worktree, base)) }
        if let opsError { throw opsError }
    }
}

/// Scripted link graphs: every build answers `graph` as it is when the
/// call arrives; calls are recorded with the fingerprint they were for.
final class FakeReviewGraphs: ReviewGraphBuilding, @unchecked Sendable {
    struct Call {
        let fingerprint: String
        let at: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private var _graph: LinkGraph
    private var _calls: [Call] = []
    private var gate: CallGate?
    private var _texts: [String: String] = [:]

    init(_ graph: LinkGraph = .empty) { _graph = graph }

    var graph: LinkGraph {
        get { lock.withLock { _graph } }
        set { lock.withLock { _graph = newValue } }
    }

    /// Head texts for the read-only file view, by path.
    var texts: [String: String] {
        get { lock.withLock { _texts } }
        set { lock.withLock { _texts = newValue } }
    }

    var calls: [Call] { lock.withLock { _calls } }

    /// The next build parks until the gate is released.
    func holdNextBuild() -> CallGate {
        let gate = CallGate()
        lock.withLock { self.gate = gate }
        return gate
    }

    func build(worktree: String, comparison: GitComparison, state: ComparisonState) async -> LinkGraph {
        let (answer, gate): (LinkGraph, CallGate?) = lock.withLock {
            _calls.append(Call(fingerprint: state.fingerprint, at: .now))
            defer { self.gate = nil }
            return (_graph, self.gate)
        }
        if let gate { try? await gate.hold() }
        return answer
    }

    func headText(worktree: String, comparison: GitComparison, path: String) async -> String? {
        lock.withLock { _texts[path] }
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
                     store: ReviewStore? = nil,
                     graphs: FakeReviewGraphs = FakeReviewGraphs(),
                     worktree: String = NSTemporaryDirectory()) -> (ReviewModel, ReviewStore) {
    let store = store ?? ReviewStore(
        root: "\(NSTemporaryDirectory())covey-reviews-\(UInt32.random(in: 0..<UInt32.max))", debounce: 0)
    let model = ReviewModel(worktree: worktree, projectRoot: "/proj", originSession: "origin",
                            git: git, store: store, directory: directory, graphs: graphs)
    model.enterDelay = .zero
    model.toastDuration = .seconds(60)
    return (model, store)
}
