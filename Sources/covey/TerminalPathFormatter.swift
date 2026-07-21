import Foundation

/// Converts one absolute local path into one POSIX shell argument.
/// Structural terminal controls are rejected rather than encoded.
func shellQuotedTerminalPath(_ path: String) -> String? {
    guard !path.isEmpty,
          NSString(string: path).isAbsolutePath,
          !path.contains("\0"),
          !path.contains("\r"),
          !path.contains("\n") else {
        return nil
    }

    let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
}
