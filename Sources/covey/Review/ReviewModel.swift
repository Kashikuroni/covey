import Foundation
import Observation
import CoreGraphics
import CoveyGit
import CoveyKit

enum ReviewPhase: Equatable {
    case loading
    case ready
    case missingWorktree
    case needsComparison(error: String?)
}

enum DiffPanelState: Equatable {
    case idle
    case loading
    case loaded(FileDiff)
    case binary
    /// Collapsed until "Load anyway"; nil lines = untracked file without counts.
    case tooLarge(lines: Int?)
    case failed(String)
}

enum DiffLayout: String, CaseIterable { case split, unified }
enum SidebarTab: String { case files, issues }
enum IssueListFilter: String, CaseIterable { case open = "Open", all = "All" }

struct ReviewToast: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// A fresh value per request, so asking for the same row twice still scrolls.
struct ScrollRequest: Equatable {
    let id = UUID()
    let rowID: String
}

struct ReviewComposer: Equatable {
    var anchor: LineAnchor
    var draft = ""
    var severity: IssueSeverity = .medium
}

struct SendDraft: Equatable {
    var target: String?
    var candidateIssueIDs: [Int]
    var candidateCommentIDs: [UUID]
    var issueIDs: Set<Int>
    var commentIDs: Set<UUID>
}

/// State and behavior of one review. Stored state is internal (not
/// private(set)) because the +Annotations/+Send/+Freshness extensions live
/// in their own files; views change it only through methods, except for
/// plain UI toggles bound directly (filter, layout, tabs).
@Observable @MainActor
final class ReviewModel {
    static let collapseThreshold = 5000

    let worktree: String
    let projectRoot: String
    let originSession: String?
    @ObservationIgnored let git: ReviewGitReading
    @ObservationIgnored let store: ReviewStore
    @ObservationIgnored weak var directory: ReviewSessionDirectory?
    @ObservationIgnored var enterDelay: Duration = .milliseconds(150)
    @ObservationIgnored var toastDuration: Duration = .seconds(3)

    // Comparison
    var phase: ReviewPhase = .loading
    var record: ReviewRecord
    var state: ComparisonState?
    var branchLabel = ""
    var localBranches: [String] = []
    var suggestedBase: String?
    var banner: String?
    var toasts: [ReviewToast] = []
    /// Bumped whenever the comparison changes (`open`). An async result that
    /// finds it moved belongs to a comparison the user has left and is dropped.
    @ObservationIgnored var loadGeneration = 0

    // Diff panel
    var selectedPath: String?
    var diff: DiffPanelState = .idle
    var diffOpen = false
    var layout: DiffLayout = .split
    var fullFile = false
    var currentStop = 0
    var scrollRequest: ScrollRequest?
    @ObservationIgnored var forceLoad: Set<String> = []
    /// Bumped by every `loadDiff`; only the newest request may publish its
    /// result, so an older fetch of the same file cannot land last.
    @ObservationIgnored var diffToken = 0

    // Chrome
    var sidebarVisible = true
    var sidebarTab: SidebarTab = .files
    var issueFilter: IssueListFilter = .open
    var filter = FileFilter()
    var collapsedDirs: Set<String> = []
    var comparisonPopoverOpen = false
    var keysOverlayOpen = false
    /// Share of the width the diff panel takes (0.3…0.8); it survives trips
    /// back to the sessions.
    var diffFraction: CGFloat = 0.55

    // Canvas
    var canvas = CanvasTransform()
    var canvasViewport: CGSize = .zero
    @ObservationIgnored var canvasFitted = false

    // Annotations and sending (behavior in +Annotations / +Send)
    var composer: ReviewComposer?
    var sendDraft: SendDraft?
    var sendError: String?
    var sending = false
    @ObservationIgnored var issueCursor: Int?

    // Freshness (behavior in +Freshness)
    @ObservationIgnored var isVisible = true
    @ObservationIgnored var failureStreak = 0
    @ObservationIgnored var reloading = false

    init(worktree: String, projectRoot: String, originSession: String?,
         git: ReviewGitReading, store: ReviewStore, directory: ReviewSessionDirectory?) {
        self.worktree = worktree
        self.projectRoot = projectRoot
        self.originSession = originSession
        self.git = git
        self.store = store
        self.directory = directory
        self.record = ReviewRecord(worktree: worktree, comparison: GitComparison(base: ""))
    }

    // MARK: - Loading

    func start() async {
        phase = .loading
        guard FileManager.default.fileExists(atPath: worktree),
              let label = await git.branchLabel(worktree: worktree) else {
            phase = .missingWorktree
            return
        }
        branchLabel = label
        localBranches = await git.localBranches(worktree: worktree)
        suggestedBase = await git.defaultBase(worktree: worktree)
        if let last = store.lastComparison(worktree: worktree) {
            await open(last)
        } else if let base = suggestedBase {
            await open(GitComparison(base: base))
        } else {
            phase = .needsComparison(error: nil)
            comparisonPopoverOpen = true
        }
    }

    /// Switches to `comparison`: loads its saved record, then the changes.
    func open(_ comparison: GitComparison) async {
        loadGeneration += 1
        let generation = loadGeneration
        // Not `.ready` while `state` is gone: the canvas would claim an empty
        // comparison, and a poll must not reload during the re-check below.
        // An abandoned open leaves the phase to the newer one.
        phase = .loading
        store.flush()
        let loaded = store.load(worktree: worktree, comparison: comparison)
        record = loaded.record
        if record.targetSession == nil { record.targetSession = originSession }
        if loaded.recovered { toast("Saved review data was unreadable — started fresh") }
        state = nil
        selectedPath = nil
        diff = .idle
        diffOpen = false
        composer = nil
        fullFile = false
        currentStop = 0
        forceLoad = []
        canvasFitted = false
        do {
            let fresh = try await git.changes(worktree: worktree, comparison: comparison)
            guard generation == loadGeneration else { return }
            apply(fresh)
            // The saved record may predate edits made while this comparison
            // was not loaded, and the first poll would match this very read.
            await invalidateReviewed(old: nil, new: fresh)
            guard generation == loadGeneration else { return }
            await recheckAnchors()
            // The re-check awaits git; a switch during it abandons this open.
            guard generation == loadGeneration else { return }
            phase = .ready
            banner = nil
            failureStreak = 0
            comparisonPopoverOpen = false
            store.setLastComparison(comparison, worktree: worktree)
            persist()
            if canvasViewport.width > 0 { fitCanvas() }
        } catch {
            guard generation == loadGeneration else { return }
            phase = .needsComparison(error: Self.describeLoad(error))
            comparisonPopoverOpen = true
        }
    }

    func retry() async {
        guard !record.comparison.base.isEmpty else {
            comparisonPopoverOpen = true
            return
        }
        if state != nil {
            await reload()
        } else {
            await open(record.comparison)
        }
    }

    /// Adopts a fresh read; files seen for the first time start unread.
    func apply(_ fresh: ComparisonState) {
        state = fresh
        for file in fresh.files where record.files[file.path] == nil {
            record.files[file.path] = FileReview()
        }
    }

    func persist() { store.save(record) }
    func flush() { store.flush() }

    func toast(_ text: String) {
        let toast = ReviewToast(text: text)
        toasts.append(toast)
        let duration = toastDuration
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            self?.toasts.removeAll { $0.id == toast.id }
        }
    }

    static func describeLoad(_ error: Error) -> String {
        (error as? GitError)?.description ?? "\(error)"
    }

    static func describeDiff(_ error: Error) -> String {
        guard let gitError = error as? GitError else { return "\(error)" }
        switch gitError.kind {
        case .timedOut, .outputTooLarge: return "Diff too large or timed out"
        default: return gitError.description
        }
    }

    // MARK: - Lookups

    var files: [ChangedFile] { state?.files ?? [] }

    func file(_ path: String) -> ChangedFile? { files.first { $0.path == path } }

    func review(for path: String) -> FileReview { record.files[path] ?? FileReview() }

    func hasOpenIssues(_ path: String) -> Bool {
        record.issues.contains { $0.anchor.path == path && $0.status.isActive }
    }

    func openIssueCount(_ path: String) -> Int {
        record.issues.filter { $0.anchor.path == path && $0.status.isActive }.count
    }

    func commentCount(_ path: String) -> Int {
        record.comments.filter { $0.anchor.path == path }.count
    }

    var reviewedCount: Int { files.filter { review(for: $0.path).state == .reviewed }.count }

    var progressFraction: Double {
        files.isEmpty ? 0 : Double(reviewedCount) / Double(files.count)
    }

    func matchesFilter(_ file: ChangedFile) -> Bool {
        ReviewFileTree.matches(file, filter: filter, review: review(for: file.path),
                               hasOpenIssues: hasOpenIssues(file.path))
    }

    var filteredFiles: [ChangedFile] { ReviewFileTree.sorted(files).filter(matchesFilter) }

    var treeRows: [FileTreeRow] { ReviewFileTree.rows(filteredFiles, collapsed: collapsedDirs) }

    func toggleDirectory(_ dir: String) {
        if collapsedDirs.contains(dir) { collapsedDirs.remove(dir) } else { collapsedDirs.insert(dir) }
    }

    var cardFrames: [CanvasCardFrame] { CanvasLayout.frames(for: files) }

    // MARK: - Diff

    func select(_ path: String?) async {
        if selectedPath != path {
            currentStop = 0
            if composer?.anchor.path != path { composer = nil }
        }
        selectedPath = path
        guard let path, let file = file(path) else {
            diff = .idle
            return
        }
        diffOpen = true
        if review(for: path).state == .unread {
            record.files[path, default: FileReview()].state = .reviewing
            persist()
        }
        await loadDiff(for: file)
    }

    func loadDiff(for file: ChangedFile, showLoading: Bool = true) async {
        // Bumped before any early return: a synchronous binary/collapsed
        // outcome also supersedes an older fetch still in flight.
        diffToken += 1
        let token = diffToken
        guard let state else { return }
        if file.isBinary {
            diff = .binary
            return
        }
        if !forceLoad.contains(file.path) {
            if file.isUntracked && file.added == nil {
                diff = .tooLarge(lines: nil)
                return
            }
            let size = (file.added ?? 0) + (file.removed ?? 0)
            if size > Self.collapseThreshold {
                diff = .tooLarge(lines: size)
                return
            }
        }
        if showLoading { diff = .loading }
        do {
            let loaded = try await git.diff(worktree: worktree, comparison: record.comparison,
                                            mergeBase: state.mergeBase, file: file, fullFile: fullFile)
            guard token == diffToken, selectedPath == file.path else { return }
            diff = loaded.isBinary ? .binary : .loaded(loaded)
            currentStop = min(currentStop, max(stops.count - 1, 0))
        } catch {
            guard token == diffToken, selectedPath == file.path else { return }
            diff = .failed(Self.describeDiff(error))
        }
    }

    func reloadSelectedDiff() async {
        guard let path = selectedPath, let file = file(path) else { return }
        await loadDiff(for: file)
    }

    func loadAnyway() async {
        guard let path = selectedPath else { return }
        forceLoad.insert(path)
        await reloadSelectedDiff()
    }

    func toggleFullFile() async {
        fullFile.toggle()
        await reloadSelectedDiff()
    }

    func toggleReviewed() async {
        guard let path = selectedPath, let file = file(path) else { return }
        let generation = loadGeneration
        var review = review(for: path)
        if review.state == .reviewed {
            review.state = .reviewing
            review.reviewedDiffHash = nil
        } else {
            review.state = .reviewed
            review.changedSinceReviewed = false
            review.reviewedDiffHash = await currentHash(of: file)
        }
        // The hash read can outlive a comparison switch; `record` is then
        // another comparison's and must not receive this file's state.
        guard generation == loadGeneration else { return }
        record.files[path] = review
        persist()
    }

    /// Hash of the file's (hunk-mode) diff as it is now; nil if it cannot be read.
    func currentHash(of file: ChangedFile) async -> String? {
        let stamp = state?.stamps[file.path]
        if file.isBinary || (file.isUntracked && file.added == nil) {
            return ReviewHash.of(.empty, file: file, stamp: stamp)
        }
        if !fullFile, selectedPath == file.path, case .loaded(let loaded) = diff {
            return ReviewHash.of(loaded, file: file, stamp: stamp)
        }
        guard let state,
              let fresh = try? await git.diff(worktree: worktree, comparison: record.comparison,
                                              mergeBase: state.mergeBase, file: file, fullFile: false)
        else { return nil }
        return ReviewHash.of(fresh, file: file, stamp: stamp)
    }

    // MARK: - Navigation

    func nextFile(_ step: Int) async {
        let list = filteredFiles
        guard !list.isEmpty else { return }
        let next: Int
        if let index = list.firstIndex(where: { $0.path == selectedPath }) {
            next = ((index + step) % list.count + list.count) % list.count
        } else {
            next = step >= 0 ? 0 : list.count - 1
        }
        await select(list[next].path)
    }

    func nextUnreviewed() async {
        let list = ReviewFileTree.sorted(files)
        guard !list.isEmpty else { return }
        let start = list.firstIndex { $0.path == selectedPath }.map { $0 + 1 } ?? 0
        for offset in 0..<list.count {
            let candidate = list[(start + offset) % list.count]
            if review(for: candidate.path).state != .reviewed {
                await select(candidate.path)
                return
            }
        }
        toast("Everything is reviewed")
    }

    var stops: [DiffStop] {
        if case .loaded(let loaded) = diff { return DiffSplitLayout.stops(loaded) }
        return []
    }

    var stopLabel: String {
        let count = stops.count
        return count == 0 ? "0/0" : "\(currentStop + 1)/\(count)"
    }

    func jumpStop(_ step: Int) {
        let all = stops
        guard !all.isEmpty else { return }
        currentStop = ((currentStop + step) % all.count + all.count) % all.count
        if let id = rowID(for: all[currentStop]) { scrollRequest = ScrollRequest(rowID: id) }
    }

    func rowID(for stop: DiffStop) -> String? {
        guard case .loaded(let loaded) = diff, loaded.hunks.indices.contains(stop.hunk) else { return nil }
        switch layout {
        case .unified:
            return DiffSplitLayout.rowID(hunk: stop.hunk, line: stop.line)
        case .split:
            return DiffSplitLayout.splitRowID(loaded.hunks[stop.hunk], hunkIndex: stop.hunk, lineIndex: stop.line)
        }
    }

    // MARK: - Canvas

    func setCanvasViewport(_ size: CGSize) {
        canvasViewport = size
        fitCanvasIfNeeded()
    }

    /// Fits once files exist and no file-bearing fit has happened yet — also
    /// when the first files arrive later through a reload.
    func fitCanvasIfNeeded() {
        if !canvasFitted, !files.isEmpty, canvasViewport.width > 0 { fitCanvas() }
    }

    /// Fitting nothing only resets the transform; the canvas counts as fitted
    /// once a fit had at least one file to frame.
    func fitCanvas() {
        canvas = CanvasTransform.fit(CanvasLayout.bounds(cardFrames), in: canvasViewport)
        canvasFitted = !files.isEmpty
    }

    func zoomCanvas(by factor: CGFloat) {
        canvas = canvas.zoomed(by: factor, around: CGPoint(x: canvasViewport.width / 2,
                                                          y: canvasViewport.height / 2))
    }

    func resetZoom() { zoomCanvas(by: 1 / canvas.zoom) }

    func focusCard() {
        guard let path = selectedPath, let frame = cardFrames.first(where: { $0.path == path }) else { return }
        canvas = canvas.centered(on: frame.rect, in: canvasViewport)
    }

    // MARK: - Escape

    /// Closes the topmost thing: overlay/sheet → composer → comparison
    /// popover → full-file mode → diff panel.
    func escape() async {
        if keysOverlayOpen {
            keysOverlayOpen = false
        } else if sendDraft != nil {
            sendDraft = nil
            sendError = nil
        } else if composer != nil {
            composer = nil
        } else if comparisonPopoverOpen {
            comparisonPopoverOpen = false
        } else if fullFile {
            await toggleFullFile()
        } else if diffOpen {
            diffOpen = false
        }
    }
}
