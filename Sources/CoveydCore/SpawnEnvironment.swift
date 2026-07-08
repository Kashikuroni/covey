import Foundation

/// Terminal-capability variables the session children need but a
/// Finder-spawned daemon lacks. The GUI renders through SwiftTerm, which
/// speaks truecolor xterm — without these, TUIs probe a dumb terminal and
/// fall back to monochrome ASCII. Existing values are never overridden.
/// Deliberately NOT setting CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN: inline
/// claude was tried (smooth viewport scrolling of the chat) and reverted —
/// on every pane resize the normal-buffer transcript reflows into mush and
/// ink's redraw leaves duplicate blocks in the scrollback.
public func terminalEnvDefaults(
    _ current: [String: String]
) -> [(key: String, value: String)] {
    [("TERM", "xterm-256color"),
     ("COLORTERM", "truecolor"),
     ("LANG", "en_US.UTF-8")].filter { current[$0.0] == nil }
}
