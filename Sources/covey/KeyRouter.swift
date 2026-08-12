import Foundation

enum InputMode: Equatable {
    case normal
    case leader(LeaderMenu)
    case selectSession
    case help
    case limits
}

enum LeaderMenu: Equatable { case root, git, session, terminal, ui, project }

/// One line of the which-key panel — pure data so it lives next to the router
/// (the single source of truth for the leader tree) and the view just draws it.
struct LeaderRow: Equatable {
    let key: String
    let label: String
    let implemented: Bool
}

extension LeaderMenu {
    /// The rows the which-key panel shows for this menu. Kept beside
    /// `routeLeader` so a chord and its visible row never drift apart.
    var rows: [LeaderRow] {
        switch self {
        case .root: return [
            LeaderRow(key: "g", label: "git — issue · list · promote · delete branch · cleanup · return", implemented: true),
            LeaderRow(key: "s", label: "session — rename · restart · verify · nvim", implemented: true),
            LeaderRow(key: "t", label: "terminal — split v · split h · close", implemented: true),
            LeaderRow(key: "u", label: "ui — session list · inspector · footer · header · theme", implemented: true),
            LeaderRow(key: "p", label: "project — add · remove", implemented: true),
            LeaderRow(key: "l", label: "limits detail", implemented: true),
        ]
        case .git: return [
            LeaderRow(key: "i", label: "create github issue", implemented: true),
            LeaderRow(key: "l", label: "list issues", implemented: true),
            LeaderRow(key: "p", label: "promote worktree to root", implemented: true),
            LeaderRow(key: "b", label: "delete session branch", implemented: true),
            LeaderRow(key: "c", label: "cleanup merged branches", implemented: true),
            LeaderRow(key: "r", label: "return to repo root", implemented: true),
        ]
        case .session: return [
            LeaderRow(key: "r", label: "rename session", implemented: true),
            LeaderRow(key: "R", label: "rename project", implemented: true),
            LeaderRow(key: "u", label: "restart session", implemented: true),
            LeaderRow(key: "U", label: "restart all claude sessions", implemented: true),
            LeaderRow(key: "v", label: "verify / cancel (later)", implemented: false),
            LeaderRow(key: "V", label: "verification details (later)", implemented: false),
            LeaderRow(key: "e", label: "nvim in agent dir (later)", implemented: false),
        ]
        case .terminal: return [
            LeaderRow(key: "v", label: "vertical split — shell beside agent", implemented: true),
            LeaderRow(key: "h", label: "horizontal split — shell below agent", implemented: true),
            LeaderRow(key: "x", label: "close split", implemented: true),
        ]
        case .ui: return [
            LeaderRow(key: "s", label: "toggle session list", implemented: true),
            LeaderRow(key: "i", label: "toggle inspector", implemented: true),
            LeaderRow(key: "a", label: "toggle agent trace", implemented: true),
            LeaderRow(key: "f", label: "toggle footer", implemented: true),
            LeaderRow(key: "h", label: "toggle header", implemented: true),
            LeaderRow(key: "t", label: "toggle dark / light theme", implemented: true),
            LeaderRow(key: "l", label: "cycle limits / clock position", implemented: true),
        ]
        case .project: return [
            LeaderRow(key: "a", label: "add project — folder picker", implemented: true),
            LeaderRow(key: "d", label: "remove project", implemented: true),
        ]
        }
    }
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
    case openLeader
    case leaderDescend(LeaderMenu)
    case leaderBack
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
        case " ": return .openLeader
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

    private static func routeLeader(_ menu: LeaderMenu, _ input: KeyInput, _ ch: Character?) -> KeyAction? {
        if input.special == .escape { return .closeOverlay }
        if menu != .root, input.special == .backspace { return .leaderBack }
        switch (menu, ch) {
        case (.root, "g"): return .leaderDescend(.git)
        case (.root, "s"): return .leaderDescend(.session)
        case (.root, "t"): return .leaderDescend(.terminal)
        case (.root, "u"): return .leaderDescend(.ui)
        case (.root, "p"): return .leaderDescend(.project)
        case (.root, "l"): return .command(.showLimitsDetail)
        case (.ui, "s"): return .command(.toggleSessionsPanel)
        case (.ui, "i"): return .command(.toggleInspector)
        case (.ui, "a"): return .command(.toggleAgentTrace)
        case (.ui, "f"): return .command(.toggleStatusBar)
        case (.ui, "h"): return .command(.toggleTopBar)
        case (.ui, "t"): return .command(.toggleTheme)
        case (.ui, "l"): return .command(.cycleUsagePlacement)
        case (.terminal, "v"): return .command(.splitTerminalVertically)
        case (.terminal, "h"): return .command(.splitTerminalHorizontally)
        case (.terminal, "x"): return .command(.closeTerminalSplit)
        case (.git, "i"): return .command(.createGitHubIssue)
        case (.git, "l"): return .command(.openIssueList)
        case (.git, "p"): return .command(.promoteWorktree)
        case (.git, "b"): return .command(.deleteSessionBranch)
        case (.git, "c"): return .command(.cleanupMergedBranches)
        case (.git, "r"): return .command(.returnToRepositoryRoot)
        case (.session, "u"): return .command(.restartSession)
        case (.session, "U"): return .command(.restartAllClaudeSessions)
        case (.session, "r"): return .command(.renameSession)
        case (.session, "R"): return .command(.renameProject)
        case (.project, "a"): return .command(.addProject)
        case (.project, "d"): return .command(.removeProject)
        // Every other command in the tree is a later slice; like the TUI,
        // an unbound key closes the leader.
        default: return .closeOverlay
        }
    }
}
