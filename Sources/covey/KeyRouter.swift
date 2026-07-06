import Foundation

enum InputMode: Equatable {
    case normal
    case leader(LeaderMenu)
    case selectSession
    case help
    case note
}

enum LeaderMenu: Equatable { case root, git, session, app, terminal }

/// Non-character keys the router cares about.
enum Special: Equatable {
    case escape, enter, tab, backspace, up, down, left, right, pageUp, pageDown, end
}

/// Harness-agnostic key event (built from NSEvent in the view layer).
struct KeyInput: Equatable {
    var char: Character?
    var isControl = false
    var isShift = false
    var special: Special?
}

enum KeyAction: Equatable {
    case selectNext, selectPrev, selectFirst
    case enterTerminal
    case exitTerminal
    case newSession(prefillDir: Bool)
    case killSelected
    case startFilter
    case openLeader
    case leaderDescend(LeaderMenu)
    case leaderBack
    case closeOverlay
    case renameSelected
    case enterSelectMode
    case selectByNumber(Int)
    case resizeSplit(Int)
    case moveSelected(up: Bool)
    case scrollTerminalPage(up: Bool)
    case scrollTerminalToBottom
    case showHelp
    case toggleSessionNote
    case toggleProjectNote
    case noteCursor(down: Bool)
    case noteToggleTask
    case noteVisual
    case noteYank
    case noteDelete
    case noteEdit
    case noteArmClear
    case noteDefocus
    case noteEscape
    case renameProject
    case answerPrompt(Int)
    case sendShiftTab
    case promoteSelected
    case deleteBranchSelected
    case cleanupBranches
    case restartSelected
    case restartAllPrompt
    case returnToRoot
    case toggleTheme
    case splitVertical
    case splitHorizontal
    case splitClose
    case splitFocusToggle
    case cycleFocus(forward: Bool)
    case openRecent
    case createIssue
}

/// Map a Cyrillic char to the Latin key at the same physical QWERTY position;
/// non-Cyrillic passes through. Port of amux-core keymap::latinize — vim-style
/// chords keep working on the ЙЦУКЕН layout. Case is preserved.
func latinize(_ c: Character) -> Character {
    let cyr = Array("йцукенгшщзхъфывапролджэячсмитьбю")
    let lat = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,.")
    let lower = Character(c.lowercased())
    guard let pos = cyr.firstIndex(of: lower) else { return c }
    let mapped = lat[pos]
    return c.isUppercase ? Character(mapped.uppercased()) : mapped
}

/// Pure key → action mapping; port of amux-tui App::handle_key dispatch.
enum KeyRouter {
    struct Context {
        var mode: InputMode
        var focus: AppModel.Focus
        var vimMode: Bool
        var sheetOpen: Bool
    }

    static func route(_ input: KeyInput, context: Context) -> KeyAction? {
        guard !context.sheetOpen else { return nil }
        let ch = input.char.map(latinize)

        if context.focus == .terminal {
            if input.isControl, ch == "q" { return .exitTerminal }
            if input.isControl, ch == "\\" { return .splitFocusToggle }
            if input.isControl, ch == "l" { return .cycleFocus(forward: true) }
            if input.isControl, ch == "h" { return .cycleFocus(forward: false) }
            // SwiftTerm does not map ⇧Tab; unhandled it falls through to
            // AppKit's focus traversal (insertBacktab:). Forward it to the
            // agent instead — the TUI's mode-cycle key.
            if input.special == .tab, input.isShift { return .sendShiftTab }
            return nil
        }
        guard context.vimMode else { return nil }

        switch context.mode {
        case .normal:
            return routeNormal(input, ch)
        case .leader(let menu):
            return routeLeader(menu, input, ch)
        case .selectSession:
            if input.special == .escape { return .closeOverlay }
            if let ch, let n = ch.wholeNumberValue, (1...9).contains(n) {
                return .selectByNumber(n)
            }
            return nil   // anything else is ignored; the mode stays
        case .help:
            return .closeOverlay
        case .note:
            return routeNote(input, ch)
        }
    }

    private static func routeNote(_ input: KeyInput, _ ch: Character?) -> KeyAction? {
        switch input.special {
        case .down: return .noteCursor(down: true)
        case .up: return .noteCursor(down: false)
        case .tab: return .noteDefocus
        case .escape: return .noteEscape
        default: break
        }
        switch ch {
        case "j": return .noteCursor(down: true)
        case "k": return .noteCursor(down: false)
        case " ": return .noteToggleTask
        case "V": return .noteVisual
        case "y": return .noteYank
        case "d": return .noteDelete
        case "e": return .noteEdit
        case "c": return .noteArmClear
        default: return nil
        }
    }

    private static func routeNormal(_ input: KeyInput, _ ch: Character?) -> KeyAction? {
        if input.isControl {
            switch input.special {
            case .left: return .resizeSplit(-8)
            case .right: return .resizeSplit(8)
            default: break
            }
            switch ch {
            case "k": return .scrollTerminalPage(up: true)
            case "j": return .scrollTerminalPage(up: false)
            // ⌃h/⌃l walk the focus zones (list -> agent -> shell -> inspector).
            case "l": return .cycleFocus(forward: true)
            case "h": return .cycleFocus(forward: false)
            case "\\": return .splitFocusToggle
            default: return nil
            }
        }
        switch input.special {
        case .down: return .selectNext
        case .up: return .selectPrev
        case .enter: return .enterTerminal
        case .tab: return input.isShift ? .sendShiftTab : nil
        case .pageUp: return .scrollTerminalPage(up: true)
        case .pageDown: return .scrollTerminalPage(up: false)
        case .end: return .scrollTerminalToBottom
        default: break
        }
        switch ch {
        case "j": return .selectNext
        case "k": return .selectPrev
        case "g": return .selectFirst
        case "G": return .scrollTerminalToBottom
        case "o": return .enterTerminal
        case "n": return .newSession(prefillDir: false)
        case "N": return .newSession(prefillDir: true)
        case "r": return .openRecent
        case "d": return .killSelected
        case "/": return .startFilter
        case "s": return .enterSelectMode
        case "t": return .toggleSessionNote
        case "T": return .toggleProjectNote
        case " ": return .openLeader
        case "K": return .moveSelected(up: true)
        case "J": return .moveSelected(up: false)
        case "[": return .resizeSplit(-3)
        case "]": return .resizeSplit(3)
        case "{": return .resizeSplit(-8)
        case "}": return .resizeSplit(8)
        case "?": return .showHelp
        default:
            if let n = ch?.wholeNumberValue, (1...9).contains(n) {
                return .answerPrompt(n)
            }
            return nil
        }
    }

    private static func routeLeader(_ menu: LeaderMenu, _ input: KeyInput, _ ch: Character?) -> KeyAction? {
        if input.special == .escape { return .closeOverlay }
        if menu != .root, input.special == .backspace { return .leaderBack }
        switch (menu, ch) {
        case (.root, "g"): return .leaderDescend(.git)
        case (.root, "s"): return .leaderDescend(.session)
        case (.root, "a"): return .leaderDescend(.app)
        case (.root, "t"): return .leaderDescend(.terminal)
        case (.terminal, "v"): return .splitVertical
        case (.terminal, "h"): return .splitHorizontal
        case (.terminal, "x"): return .splitClose
        case (.git, "i"): return .createIssue
        case (.git, "p"): return .promoteSelected
        case (.git, "b"): return .deleteBranchSelected
        case (.git, "c"): return .cleanupBranches
        case (.git, "r"): return .returnToRoot
        case (.session, "u"): return .restartSelected
        case (.app, "u"): return .restartAllPrompt
        case (.app, "t"): return .toggleTheme
        case (.session, "r"): return .renameSelected
        case (.session, "R"): return .renameProject
        // Every other command in the tree is a later slice; like the TUI,
        // an unbound key closes the leader.
        default: return .closeOverlay
        }
    }
}
