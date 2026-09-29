import Foundation
import CoveyGit

enum AnchorCheck: Equatable {
    case current
    case moved(to: Int)
    case outdated
    case fileGone
}

enum AnchorTracker {
    /// `fullDiff` is the whole-file diff (`fullFile: true`), so every line of
    /// both sides is present; nil means the file left the comparison.
    static func check(_ anchor: LineAnchor, in fullDiff: FileDiff?) -> AnchorCheck {
        guard let fullDiff else { return .fileGone }
        let side: [(number: Int, text: String)] = fullDiff.hunks.flatMap(\.lines).compactMap { line in
            let number = anchor.side == .new ? line.newNumber : line.oldNumber
            return number.map { ($0, line.text) }
        }
        if side.contains(where: { $0.number == anchor.line && $0.text == anchor.lineText }) {
            return .current
        }
        let hits = side.filter { $0.text == anchor.lineText }
        return hits.count == 1 ? .moved(to: hits[0].number) : .outdated
    }
}
