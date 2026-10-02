import Foundation
import CoveyGit
import CoveyCodeGraph

/// The right panel's read-only view of a file (Review spec part 3,
/// «Взаимодействие»): its head text, usage lines highlighted, scrolled to
/// one of them. No comments or issues live here.
struct ReviewFileView: Equatable {
    enum Content: Equatable {
        case loading
        case text([String])
        /// Missing, binary, not UTF-8 or over 1 MB.
        case unavailable
    }

    let path: String
    var content: Content = .loading
    /// 1-based lines to highlight.
    var highlighted: Set<Int>
    /// The line to scroll to; nil — the top.
    var line: Int?
}

extension ReviewModel {
    /// A neighbour card's usage lines: where the neighbour uses the selected
    /// file, or where the selected file uses the neighbour.
    func neighbourSites(_ card: GraphCard) -> [UsageSite] {
        guard let key = neighbourKey(card) else { return [] }
        return linkGraph?.usages[key] ?? []
    }

    func neighbourKey(_ card: GraphCard) -> LinkKey? {
        guard let selected = selectedPath else { return nil }
        switch card.kind {
        case .user: return LinkKey(from: card.path, to: selected)
        case .used: return LinkKey(from: selected, to: card.path)
        case .changed: return nil
        }
    }

    /// Shows `path` read-only in the right panel. Only the newest request
    /// may fill the panel.
    func openFile(_ path: String, line: Int?, highlighted: Set<Int>) async {
        fileViewToken += 1
        let token = fileViewToken
        fileView = ReviewFileView(path: path, highlighted: highlighted, line: line)
        let text = await graphs.headText(worktree: worktree, comparison: record.comparison, path: path)
        guard token == fileViewToken else { return }
        fileView?.content = text.map { .text(Self.fileLines($0)) } ?? .unavailable
    }

    /// A usage line on a neighbour card: its file, at that line, with every
    /// usage of the same link highlighted.
    func openUsage(_ site: UsageSite, of key: LinkKey) async {
        let lines = (linkGraph?.usages[key] ?? []).filter { $0.path == site.path }.map(\.line)
        await openFile(site.path, line: site.line, highlighted: Set(lines))
    }

    /// "Open file" on a neighbour card: the neighbour itself, its own usage
    /// lines (a user's) highlighted.
    func openNeighbour(_ card: GraphCard) async {
        let lines = neighbourSites(card).filter { $0.path == card.path }.map(\.line)
        await openFile(card.path, line: lines.min(), highlighted: Set(lines))
    }

    func closeFileView() {
        fileViewToken += 1
        fileView = nil
    }

    /// Lines numbered as the graph numbers them: split at "\n" only, a
    /// trailing "\r" dropped, no phantom line after a final newline.
    static func fileLines(_ text: String) -> [String] {
        var lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { scalars -> String in
                var line = String(Substring(scalars))
                if line.unicodeScalars.last == "\r" { line.unicodeScalars.removeLast() }
                return line
            }
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The read-only panel's caption: "Not in this change" only for a file
    /// outside the change, plus how many usage lines are marked in it.
    static func fileViewCaption(inChange: Bool, usageLines: Int) -> String {
        var caption = inChange ? "" : "Not in this change"
        if usageLines > 0 {
            let count = "\(usageLines) usage line\(usageLines == 1 ? "" : "s")"
            caption = caption.isEmpty ? count : caption + " · " + count
        }
        return caption
    }
}
