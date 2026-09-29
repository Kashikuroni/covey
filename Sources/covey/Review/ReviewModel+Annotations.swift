import Foundation
import CoveyGit

struct ThreadKey: Hashable {
    let side: ReviewSide
    let line: Int
}

enum ReviewThreadItem: Identifiable, Equatable {
    case comment(ReviewComment)
    case issue(ReviewIssue)

    var id: String {
        switch self {
        case .comment(let c): return "c-\(c.id.uuidString)"
        case .issue(let i): return "i-\(i.id)"
        }
    }

    var anchor: LineAnchor {
        switch self {
        case .comment(let c): return c.anchor
        case .issue(let i): return i.anchor
        }
    }

    var anchorState: AnchorState {
        switch self {
        case .comment(let c): return c.anchorState
        case .issue(let i): return i.anchorState
        }
    }

    var note: String? {
        switch self {
        case .comment(let c): return c.note
        case .issue(let i): return i.note
        }
    }
}

extension ReviewModel {
    // MARK: - Composer

    func openComposer(side: ReviewSide, line: Int, text: String) {
        guard let path = selectedPath else { return }
        composer = ReviewComposer(anchor: LineAnchor(path: path, side: side, line: line, lineText: text))
    }

    /// `C`: the first changed line of the current change stop.
    func composeAtCurrentStop() {
        guard case .loaded(let loaded) = diff else { return }
        let all = stops
        guard all.indices.contains(currentStop) else { return }
        let stop = all[currentStop]
        let line = loaded.hunks[stop.hunk].lines[stop.line]
        if let n = line.newNumber {
            openComposer(side: .new, line: n, text: line.text)
        } else if let n = line.oldNumber {
            openComposer(side: .old, line: n, text: line.text)
        }
    }

    func submitComment() {
        guard let draft = composer, let text = Self.cleaned(draft.draft) else { return }
        record.comments.append(ReviewComment(id: UUID(), anchor: draft.anchor, text: text, createdAt: Date()))
        composer = nil
        persist()
    }

    func submitIssue() {
        guard let draft = composer, let text = Self.cleaned(draft.draft) else { return }
        let id = record.nextIssueId
        record.nextIssueId += 1
        record.issues.append(ReviewIssue(id: id, anchor: draft.anchor, title: IssueTitle.make(from: text),
                                         body: text, severity: draft.severity, status: .open,
                                         createdAt: Date()))
        composer = nil
        persist()
        toast("Issue #\(id) created")
    }

    /// The draft trimmed, with "\r\n" and "\r" turned into "\n" (the prompt
    /// builder splits on "\n"); nil when nothing is left.
    private static func cleaned(_ text: String) -> String? {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = unified.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Issues

    func setStatus(_ status: IssueStatus, forIssue id: Int) {
        guard let index = record.issues.firstIndex(where: { $0.id == id }) else { return }
        record.issues[index].status = status
        persist()
    }

    var visibleIssues: [ReviewIssue] {
        let issues = issueFilter == .open ? record.issues.filter { $0.status.isActive } : record.issues
        return issues.sorted { $0.id < $1.id }
    }

    func openIssue(_ id: Int) async {
        guard let issue = record.issues.first(where: { $0.id == id }) else { return }
        await select(issue.anchor.path)
        requestScroll(to: issue.anchor)
    }

    /// `I` / `⇧I`: active issues in tree order, then by line.
    func nextIssue(_ step: Int) async {
        let order = Dictionary(ReviewFileTree.sorted(files).enumerated().map { ($1.path, $0) },
                               uniquingKeysWith: { first, _ in first })
        let active = record.issues.filter { $0.status.isActive }.sorted {
            (order[$0.anchor.path] ?? .max, $0.anchor.line, $0.id)
                < (order[$1.anchor.path] ?? .max, $1.anchor.line, $1.id)
        }
        guard !active.isEmpty else { return }
        let next: Int
        if let cursor = issueCursor {
            next = ((cursor + step) % active.count + active.count) % active.count
        } else {
            next = step >= 0 ? 0 : active.count - 1
        }
        issueCursor = next
        await openIssue(active[next].id)
    }

    func requestScroll(to anchor: LineAnchor) {
        guard case .loaded(let loaded) = diff, selectedPath == anchor.path else { return }
        for (h, hunk) in loaded.hunks.enumerated() {
            let number: (DiffLine) -> Int? = { anchor.side == .new ? $0.newNumber : $0.oldNumber }
            guard let index = hunk.lines.firstIndex(where: { number($0) == anchor.line }) else { continue }
            let id = layout == .split
                ? DiffSplitLayout.splitRowID(hunk, hunkIndex: h, lineIndex: index)
                : DiffSplitLayout.rowID(hunk: h, line: index)
            if let id { scrollRequest = ScrollRequest(rowID: id) }
            return
        }
    }

    // MARK: - Threads

    /// Inline threads of `path`: items whose anchor is current or tracked.
    func threads(for path: String) -> [ThreadKey: [ReviewThreadItem]] {
        var map: [ThreadKey: [ReviewThreadItem]] = [:]
        for item in items(for: path) where item.anchorState == .current || item.anchorState == .tracked {
            map[ThreadKey(side: item.anchor.side, line: item.anchor.line), default: []].append(item)
        }
        return map
    }

    /// Items of `path` that lost their line; shown above the diff.
    func outdatedItems(for path: String) -> [ReviewThreadItem] {
        items(for: path).filter { $0.anchorState == .outdated || $0.anchorState == .fileGone }
    }

    private func items(for path: String) -> [ReviewThreadItem] {
        record.comments.filter { $0.anchor.path == path }.sorted { $0.createdAt < $1.createdAt }
            .map(ReviewThreadItem.comment)
            + record.issues.filter { $0.anchor.path == path }.sorted { $0.id < $1.id }
            .map(ReviewThreadItem.issue)
    }

    // MARK: - Anchors

    /// Re-checks every annotated file against its whole-file diff. A file
    /// whose diff cannot be read right now (timeout, binary, over the cap)
    /// keeps its anchors as they are — never guess them gone.
    ///
    /// Each diff read can outlive a comparison switch; `record` is then
    /// another comparison's, so the check stops without writing anything.
    func recheckAnchors() async {
        guard let state else { return }
        let generation = loadGeneration
        let paths = Set(record.comments.map(\.anchor.path) + record.issues.map(\.anchor.path))
        for path in paths {
            let full: FileDiff?
            if let file = state.files.first(where: { $0.path == path }) {
                if file.isBinary || (file.isUntracked && file.added == nil) { continue }
                let loaded = try? await git.diff(worktree: worktree, comparison: record.comparison,
                                                 mergeBase: state.mergeBase, file: file, fullFile: true)
                guard generation == loadGeneration else { return }
                guard let loaded else { continue }
                full = loaded
            } else {
                full = nil
            }
            // `record` is an observed (computed) property: two inout paths
            // into it in one call would alias, so each item is edited as a copy.
            for i in record.comments.indices where record.comments[i].anchor.path == path {
                var item = record.comments[i]
                Self.applyCheck(AnchorTracker.check(item.anchor, in: full),
                                anchor: &item.anchor, state: &item.anchorState, note: &item.note)
                if item != record.comments[i] { record.comments[i] = item }
            }
            for i in record.issues.indices where record.issues[i].anchor.path == path {
                var item = record.issues[i]
                Self.applyCheck(AnchorTracker.check(item.anchor, in: full),
                                anchor: &item.anchor, state: &item.anchorState, note: &item.note)
                if item != record.issues[i] { record.issues[i] = item }
            }
        }
    }

    static func applyCheck(_ check: AnchorCheck, anchor: inout LineAnchor,
                           state: inout AnchorState, note: inout String?) {
        switch check {
        case .current:
            if state == .outdated || state == .fileGone {
                state = .current
                note = nil
            }
        case .moved(let line):
            note = "Tracked :\(anchor.line) → :\(line)"
            anchor.line = line
            state = .tracked
        case .outdated:
            state = .outdated
            note = "The line changed — this reference is outdated"
        case .fileGone:
            state = .fileGone
            note = "File no longer changed"
        }
    }
}
