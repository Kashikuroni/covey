/// Port of amux-core tmux/parse.rs: strip_ansi + parse_resume_command with its
/// strict validators. A dying claude prints `claude --resume <id>`; the value
/// is re-run through `sh -c`, so both token forms are validated strictly —
/// anything suspicious is rejected, never sanitized.

/// Removes ANSI/CSI escape sequences: skip ESC and everything up to the
/// sequence's final byte (an ASCII letter). Also drops CR — raw PTY output is
/// CRLF-terminated (the TUI original read tmux capture-pane, which is not).
/// Walks unicode scalars, not Characters: Swift folds "\r\n" into ONE grapheme
/// cluster, which would dodge both the CR filter and the "\n" line split.
func stripANSI(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    var it = s.unicodeScalars.makeIterator()
    while let c = it.next() {
        if c == "\u{1b}" {
            while let n = it.next() {
                if (65...90).contains(n.value) || (97...122).contains(n.value) { break }
            }
        } else if c != "\r" {
            out.unicodeScalars.append(c)
        }
    }
    return out
}

/// Scans output for the LAST `claude --resume <id>` hint and returns it as a
/// ready-to-run string. The command is matched anywhere in the line — the tty
/// echoes `^C` onto the hint line and claude may wrap it in prose — and text
/// after the token is ignored.
func parseResumeCommand(_ pane: String) -> String? {
    let hint = "claude --resume "
    let clean = stripANSI(pane)
    for line in clean.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
        guard let r = line.range(of: hint, options: .backwards) else { continue }
        let rest = line[r.upperBound...]
        if rest.hasPrefix("\"") {
            let name = String(rest.dropFirst().prefix(while: { $0 != "\"" }))
            if isResumeName(name) { return "\(hint)\"\(name)\"" }
        } else if let token = rest.split(separator: " ").first.map(String.init),
                  isResumeUUID(token) {
            return hint + token
        }
    }
    return nil
}

/// Quoted session names: ASCII alphanumerics plus -/_/. only (shell-safe).
private func isResumeName(_ s: String) -> Bool {
    !s.isEmpty && s.allSatisfy {
        ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" || $0 == "."
    }
}

/// Bare tokens: exactly a 36-char lowercase-hex UUID, dashes at 8/13/18/23.
private func isResumeUUID(_ s: String) -> Bool {
    let b = Array(s.utf8)
    guard b.count == 36 else { return false }
    for (i, c) in b.enumerated() {
        if i == 8 || i == 13 || i == 18 || i == 23 {
            if c != UInt8(ascii: "-") { return false }
        } else if !((c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9"))
                    || (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "f"))) {
            return false
        }
    }
    return true
}
