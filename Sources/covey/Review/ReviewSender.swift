import Foundation

enum ReviewSender {
    static let pasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]   // ESC[200~
    static let pasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]     // ESC[201~
    static let enter: [UInt8] = [0x0D]

    /// No ESC may reach the PTY: a literal `ESC[201~` in the text would end
    /// the paste early and the rest would be typed as keystrokes.
    static func sanitize(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return String(String.UnicodeScalarView(unified.unicodeScalars.filter { $0 != "\u{1B}" }))
    }

    static func pastePayload(_ text: String) -> [UInt8] {
        pasteStart + Array(sanitize(text).utf8) + pasteEnd
    }

    /// Paste, wait, Enter. A TUI can swallow an Enter that arrives in the
    /// same read as the paste end, hence the separate write after a pause.
    @MainActor
    static func deliver(_ text: String, to session: String, via directory: ReviewSessionDirectory,
                        enterDelay: Duration) async throws {
        try await directory.sendToSession(session, bytes: pastePayload(text))
        if enterDelay > .zero { try await Task.sleep(for: enterDelay) }
        try await directory.sendToSession(session, bytes: enter)
    }
}
