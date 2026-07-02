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

    // MARK: - TerminalDelegate (the daemon never answers back to the app)
    public func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
