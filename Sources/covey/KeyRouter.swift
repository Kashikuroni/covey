import Foundation

enum InputMode: Equatable {
    case normal
    case selectSession
    case help
    case limits
}

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
    case command(AppCommand)
    case selectNext, selectPrev, selectFirst
    case exitTerminal
    case closeOverlay
    case enterSelectMode
    case selectByNumber(Int)
    case resizeSplit(Int)
    case scrollTerminalPage(up: Bool)
    case scrollTerminalToBottom
    case sendShiftTab
    case sendShiftEnter
    case splitFocusToggle
    case cycleFocus(forward: Bool)
    case limitsSelectNext
    case limitsSelectPrev
    case limitsEnableSelected
    case limitsDisableSelected
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
            // Same story for ⇧Enter: SwiftTerm sends a bare CR for it (the
            // shift only shows up under the kitty keyboard protocol, which the
            // agents do not turn on), so an agent reads it as plain Enter and
            // submits instead of breaking the line.
            if input.special == .enter, input.isShift { return .sendShiftEnter }
            return nil
        }
        guard context.vimMode else { return nil }

        // Inspector j/k belongs to the issue browser. Control-j/k has no
        // inspector action and must not fall through to the session-side
        // terminal scroll commands.
        if context.focus == .inspector, input.isControl, ch == "j" || ch == "k" {
            return nil
        }

        // ⌃h/⌃l walk the focus zones from every zone and mode.
        if input.isControl {
            if ch == "l" { return .cycleFocus(forward: true) }
            if ch == "h" { return .cycleFocus(forward: false) }
        }

        switch context.mode {
        case .normal:
            return routeNormal(input, ch)
        case .selectSession:
            if input.special == .escape { return .closeOverlay }
            if let ch, let n = ch.wholeNumberValue, (1...9).contains(n) {
                return .selectByNumber(n)
            }
            return nil   // anything else is ignored; the mode stays
        case .help:
            return .closeOverlay
        case .limits:
            // j/k move the highlighted provider, h/l disable/enable it —
            // vim's "collapse/expand" pairing. Any other key still closes,
            // matching .help's "any key closes" behavior.
            switch ch {
            case "j": return .limitsSelectNext
            case "k": return .limitsSelectPrev
            case "h": return .limitsDisableSelected
            case "l": return .limitsEnableSelected
            default: return .closeOverlay
            }
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
            case "\\": return .splitFocusToggle
            default: return nil
            }
        }
        switch input.special {
        case .down: return .selectNext
        case .up: return .selectPrev
        case .enter: return .command(.focusAgent)
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
        case "o": return .command(.focusAgent)
        case "n": return .command(.newSession)
        case "N": return .command(.newSessionInCurrentProject)
        case "r": return .command(.recentSessions)
        case "d": return .command(.killSession)
        case "/": return .command(.filterSessions)
        case "s": return .enterSelectMode
        case "K": return .command(.moveSessionUp)
        case "J": return .command(.moveSessionDown)
        case "[": return .resizeSplit(-3)
        case "]": return .resizeSplit(3)
        case "{": return .resizeSplit(-8)
        case "}": return .resizeSplit(8)
        case "?": return .command(.showKeyboardHelp)
        default:
            return nil
        }
    }

}
