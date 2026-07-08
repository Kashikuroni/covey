import Foundation
import Observation

/// Spec: stale-while-revalidate with a 120 s freshness window.
let issueCacheTTL: TimeInterval = 120

/// What to do on opening a list given the cache entry's age.
enum CachePlan: Equatable {
    case useCached      // fresh: show, no network
    case revalidate     // stale: show now, refetch in background
    case fetch          // no cache: full-screen loading
}

func cachePlan(fetchedAt: Date?, ttl: TimeInterval, now: Date) -> CachePlan {
    guard let fetchedAt else { return .fetch }
    return now.timeIntervalSince(fetchedAt) <= ttl ? .useCached : .revalidate
}

/// The banner when a background refresh failed and cached data stays up.
func staleNoteText(fetchedAt: Date, now: Date) -> String {
    let minutes = Int(now.timeIntervalSince(fetchedAt) / 60)
    return "updated \(minutes)m ago — refresh failed"
}

/// State machine of the inspector's issue browser. gh access is injected
/// so the whole flow tests without a network; the UI owns no state.
@MainActor @Observable
public final class IssueBrowserModel {
    enum Screen: Equatable { case list, detail(Int), edit(Int) }
    enum Stage: Equatable { case idle, loading, ready, failed(String) }
    enum Prompt: Equatable { case closeReason(Int), deleteConfirm(Int) }

    struct CacheEntry {
        var issues: [GhIssue]
        var fetchedAt: Date
    }

    private(set) var issues: [GhIssue] = []
    private(set) var stage: Stage = .idle
    var screen: Screen = .list
    private(set) var stateFilter: IssueState = .open
    var query = "" {
        didSet { ensureSelection() }
    }
    private(set) var selectedNumber: Int?
    private(set) var revalidating = false
    private(set) var staleNote: String?
    private(set) var root: String?
    private(set) var dir: String?

    private(set) var prompt: Prompt?
    private(set) var labels: [GhLabel]?
    private(set) var labelsLoading = false
    private(set) var actionBusy = false

    private var cache: [String: CacheEntry] = [:]
    /// Key of the most recently started revalidate; used so a late-finishing
    /// stale revalidate doesn't clear the spinner out from under a newer one.
    private var revalidatingKey: String?

    /// Local branch names of the current root — the card's ⎇ WIP signal.
    private(set) var localBranches: [String] = []

    var fetchIssues: (String, IssueState) async -> GhOutcome<[GhIssue]>
    var fetchLabels: (String) async -> GhOutcome<[GhLabel]>
    var runMutation: ([String], String) async -> String?
    var fetchBranches: (String) async -> [String]
    var toast: (String) -> Void
    var now: () -> Date

    init(fetchIssues: @escaping (String, IssueState) async -> GhOutcome<[GhIssue]>,
         fetchLabels: @escaping (String) async -> GhOutcome<[GhLabel]> = { _ in .success([]) },
         runMutation: @escaping ([String], String) async -> String? = { _, _ in nil },
         fetchBranches: @escaping (String) async -> [String] = { _ in [] },
         toast: @escaping (String) -> Void = { _ in },
         now: @escaping () -> Date = Date.init) {
        self.fetchIssues = fetchIssues
        self.fetchLabels = fetchLabels
        self.runMutation = runMutation
        self.fetchBranches = fetchBranches
        self.toast = toast
        self.now = now
    }

    private func cacheKey(_ root: String, _ state: IssueState) -> String {
        "\(root)|\(state.rawValue)"
    }

    func open(root: String, dir: String) async {
        self.root = root
        self.dir = dir
        let key = cacheKey(root, stateFilter)
        switch cachePlan(fetchedAt: cache[key]?.fetchedAt, ttl: issueCacheTTL, now: now()) {
        case .useCached:
            issues = cache[key]!.issues
            stage = .ready
            ensureSelection()
        case .revalidate:
            issues = cache[key]!.issues
            stage = .ready
            ensureSelection()
            await revalidate(key: key)
        case .fetch:
            stage = .loading
            await fetchInto(key: key)
        }
        await refreshBranches(dir: dir)
    }

    func refresh(force: Bool) async {
        guard let root, let dir else { return }
        let key = cacheKey(root, stateFilter)
        if force { cache[key] = nil }
        if issues.isEmpty { stage = .loading }
        await revalidate(key: key)
        await refreshBranches(dir: dir)
    }

    /// Loads the root's local branches for the WIP badges. Awaited after the
    /// list work (a local git call, milliseconds); a late result for a
    /// switched-away root is dropped, mirroring fetchInto's currency guard.
    private func refreshBranches(dir: String) async {
        let fetched = await fetchBranches(dir)
        if self.dir == dir { localBranches = fetched }
    }

    func cycleFilter() async {
        stateFilter = stateFilter.next()
        guard let root, let dir else { return }
        await open(root: root, dir: dir)
    }

    func invalidate(root: String) {
        for state in IssueState.allCases {
            cache[cacheKey(root, state)] = nil
        }
    }

    func visible() -> [GhIssue] {
        guard !query.isEmpty else { return issues }
        return issues.filter { fuzzyMatch(query, "#\($0.number) \($0.title)") }
    }

    func selectedIssue() -> GhIssue? {
        issues.first { $0.number == selectedNumber }
    }

    func selectNumber(_ n: Int) { selectedNumber = n }

    func moveSelection(_ delta: Int) {
        let rows = visible()
        guard !rows.isEmpty else { return }
        let cur = rows.firstIndex { $0.number == selectedNumber } ?? 0
        let next = min(max(cur + delta, 0), rows.count - 1)
        selectedNumber = rows[next].number
    }

    /// Keeps the selection on the same issue number across list replacement;
    /// falls back to the first visible row.
    private func ensureSelection() {
        let rows = visible()
        if let selectedNumber, rows.contains(where: { $0.number == selectedNumber }) { return }
        selectedNumber = rows.first?.number
    }

    /// True when `key` still matches what's on screen — i.e. the user hasn't
    /// switched roots or cycled the filter since the fetch for `key` started.
    private func isCurrent(_ key: String) -> Bool {
        guard let root else { return false }
        return key == cacheKey(root, stateFilter)
    }

    private func fetchInto(key: String) async {
        guard let dir else { return }
        switch await fetchIssues(dir, stateFilter) {
        case .success(let fresh):
            // Always update the cache so a later re-open of this root/filter
            // sees fresh data, even if it's not what's on screen right now.
            cache[key] = CacheEntry(issues: fresh, fetchedAt: now())
            guard isCurrent(key) else { return }
            issues = fresh
            stage = .ready
            staleNote = nil
            ensureSelection()
        case .failure(let msg):
            guard isCurrent(key) else { return }
            if issues.isEmpty { stage = .failed(msg) }
            else if let entry = cache[key] {
                staleNote = staleNoteText(fetchedAt: entry.fetchedAt, now: now())
            } else {
                staleNote = "refresh failed: \(msg)"
            }
        }
    }

    private func revalidate(key: String) async {
        revalidatingKey = key
        revalidating = true
        await fetchInto(key: key)
        // Only clear the flag if no newer revalidate has started meanwhile —
        // otherwise this stale completion would hide the newer one's spinner.
        // An overlapping third+ revalidate can still race this cheaply (the
        // flag may drop a beat early); acceptable per spec, and it never gets
        // stuck true since the last-started revalidate always owns the clear.
        if revalidatingKey == key {
            revalidating = false
            revalidatingKey = nil
        }
    }

    /// `overrideDir` lets the composer load labels before the list was ever
    /// opened (which is what sets `dir`).
    func loadLabelsIfNeeded(dir overrideDir: String? = nil) async {
        guard labels == nil, !labelsLoading, let d = overrideDir ?? dir else { return }
        labelsLoading = true
        if case .success(let fetched) = await fetchLabels(d) { labels = fetched }
        labelsLoading = false
    }

    /// Runs one mutation; on success invalidates the root cache and refetches.
    /// Returns true on success.
    private func performMutation(_ args: [String], successToast: String) async -> Bool {
        guard let root, let dir, !actionBusy else { return false }
        actionBusy = true
        defer { actionBusy = false }
        if let error = await runMutation(args, dir) {
            toast(error)
            return false
        }
        toast(successToast)
        invalidate(root: root)
        await refresh(force: true)
        return true
    }

    func beginClose() {
        guard let issue = selectedIssue() else { return }
        guard issue.isOpen else { return }        // closed -> caller reopens
        prompt = .closeReason(issue.number)
    }

    func closeSelected(reason: CloseReason) async {
        guard case .closeReason(let n) = prompt else { return }
        prompt = nil
        _ = await performMutation(issueCloseArgs(number: n, reason: reason),
                                  successToast: "issue #\(n) closed")
    }

    func reopenSelected() async {
        guard let issue = selectedIssue(), !issue.isOpen else { return }
        _ = await performMutation(issueReopenArgs(number: issue.number),
                                  successToast: "issue #\(issue.number) reopened")
    }

    func beginDelete() {
        guard let issue = selectedIssue() else { return }
        prompt = .deleteConfirm(issue.number)
    }

    func deleteConfirmed() async {
        guard case .deleteConfirm(let n) = prompt else { return }
        prompt = nil
        let deleted = await performMutation(issueDeleteArgs(number: n),
                                            successToast: "issue #\(n) deleted")
        if deleted, case .detail(n) = screen { screen = .list }
    }

    func cancelPrompt() { prompt = nil }

    func saveEdit(number: Int, title: String?, body: String?,
                  addLabels: [String], removeLabels: [String]) async -> Bool {
        if title == nil, body == nil, addLabels.isEmpty, removeLabels.isEmpty {
            return true   // nothing changed — no gh call
        }
        let args = issueEditArgs(number: number, title: title, body: body,
                                 addLabels: addLabels, removeLabels: removeLabels)
        return await performMutation(args, successToast: "issue #\(number) updated")
    }
}
