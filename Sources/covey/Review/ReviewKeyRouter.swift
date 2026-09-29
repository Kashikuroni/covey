import Foundation

enum ReviewKeyAction: Equatable {
    case nextFile, previousFile, nextHunk, previousHunk, nextIssue, previousIssue
    case nextUnreviewed, toggleReviewed, toggleFullFile, comment
    case fit, zoomReset, zoomIn, zoomOut
    case focusTree, focusDiff, focusCard, showKeys, escape, closeWindow
}

struct ReviewKeyEvent: Equatable {
    /// `charactersIgnoringModifiers` (Shift still applies: ⇧I arrives as "I").
    var characters: String
    var isEscape = false
    var command = false
    var control = false
    var option = false
}

struct ReviewKeyContext: Equatable {
    /// A text field or text view is first responder.
    var textInputFocused = false
    /// The send sheet or the keys overlay is up.
    var modalOpen = false
}

enum ReviewKeyRouter {
    static func route(_ event: ReviewKeyEvent, context: ReviewKeyContext) -> ReviewKeyAction? {
        // Cyrillic keys map to the Latin key at the same physical position, so
        // the shortcuts also work on the ЙЦУКЕН layout.
        let key = event.characters.first.map { String(latinize($0)) } ?? ""
        if event.command {
            let plain = !event.control && !event.option
            return plain && key.lowercased() == "w" ? .closeWindow : nil
        }
        if event.isEscape { return .escape }
        if event.control || event.option || context.textInputFocused || context.modalOpen { return nil }
        if key == "I" { return .previousIssue }
        switch key.lowercased() {
        case "j": return .nextFile
        case "k": return .previousFile
        case "]": return .nextHunk
        case "[": return .previousHunk
        case "i": return .nextIssue
        case "u": return .nextUnreviewed
        case "r": return .toggleReviewed
        case "e": return .toggleFullFile
        case "c": return .comment
        case "f": return .fit
        case "0": return .zoomReset
        case "=", "+": return .zoomIn
        case "-": return .zoomOut
        case "1": return .focusTree
        case "2": return .focusDiff
        case "3": return .focusCard
        case "?": return .showKeys
        default: return nil
        }
    }

    static let help: [(label: String, keys: String)] = [
        ("Next / previous file", "J  K"),
        ("Next / previous change", "]  ["),
        ("Next / previous issue", "I  ⇧I"),
        ("Next unreviewed", "U"),
        ("Mark reviewed", "R"),
        ("Full file / hunks", "E"),
        ("Comment on current change", "C"),
        ("Fit canvas", "F"),
        ("Zoom 100%", "0"),
        ("Zoom in / out", "=  −"),
        ("Show file tree", "1"),
        ("Show diff", "2"),
        ("Center current card", "3"),
        ("This help", "?"),
        ("Close / back", "Esc"),
    ]
}
