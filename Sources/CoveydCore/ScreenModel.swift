import Foundation
import SwiftTerm

/// Headless VT screen of one session: parses the raw PTY byte stream and
/// exposes the text a user would currently see (active buffer, including the
/// alternate screen Claude Code runs in). This is the coveyd analog of
/// `tmux capture-pane` that Rust's status inference relied on.
///
/// Thread-safety: `feed` (PTY queue), `resize` (IPC queue) and `visibleText`
/// (status-monitor queue) are all serialized on an internal lock.
public final class ScreenModel: TerminalDelegate {
    private let lock = NSLock()
    private var terminal: Terminal!

    public init(cols: Int = 80, rows: Int = 24) {
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows))
    }

    public func feed(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        terminal.feed(byteArray: bytes)
    }

    public func resize(cols: Int, rows: Int) {
        lock.lock(); defer { lock.unlock() }
        terminal.resize(cols: cols, rows: rows)
    }

    /// Rows of the active buffer, right-trimmed, joined with "\n".
    /// Trailing blank rows are dropped to match `tmux capture-pane` semantics:
    /// status inference windows on the LAST lines, so a mostly-empty screen
    /// must not push real content out of that window.
    public func visibleText() -> String {
        lock.lock(); defer { lock.unlock() }
        var rows = (0..<terminal.rows)
            .compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        return rows.joined(separator: "\n")
    }

    /// DECSET bytes that put a fresh terminal emulator into this session's
    /// current private-mode state (alt screen, mouse tracking, bracketed
    /// paste, application cursor keys). Sent as an attach preamble: these
    /// modes are emitted once at process start and are usually evicted from
    /// the raw scrollback ring, so a re-attached GUI would otherwise stay in
    /// the normal buffer and mis-route wheel events. The mouse protocol is
    /// assumed SGR (1006): SwiftTerm keeps the actual encoding private, and
    /// claude/vim/lazygit all request SGR.
    public func statePreamble() -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        var seq = ""
        if terminal.isCurrentBufferAlternate { seq += "\u{1b}[?1049h" }
        switch terminal.mouseMode {
        case .off: break
        case .x10: seq += "\u{1b}[?9h"
        case .vt200: seq += "\u{1b}[?1000h"
        case .buttonEventTracking: seq += "\u{1b}[?1002h"
        case .anyEvent: seq += "\u{1b}[?1003h"
        }
        if terminal.mouseMode != .off { seq += "\u{1b}[?1006h" }
        if terminal.bracketedPasteMode { seq += "\u{1b}[?2004h" }
        if terminal.applicationCursor { seq += "\u{1b}[?1h" }
        return Array(seq.utf8)
    }

    // MARK: - TerminalDelegate (the daemon never answers back to the app)
    public func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
