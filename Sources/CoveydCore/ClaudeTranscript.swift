import Foundation

/// Locating and parsing Claude Code transcript files
/// (~/.claude/projects/<slug>/<uuid>.jsonl). Pure logic plus a bounded tail
/// reader; polling lives in ModelMonitor.
public enum ClaudeTranscript {
    /// Claude Code's project-directory slug: every non-alphanumeric ASCII
    /// character becomes "-", case preserved
    /// (/Users/x/.claude/jobs -> -Users-x--claude-jobs).
    public static func projectSlug(cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// Session uuid out of a "claude --resume <uuid>" command; nil for
    /// non-claude sessions.
    public static func sessionUUID(resumeCmd: String?) -> String? {
        guard let cmd = resumeCmd else { return nil }
        let parts = cmd.split(separator: " ")
        guard let i = parts.firstIndex(of: "--resume"), parts.indices.contains(i + 1),
              UUID(uuidString: String(parts[i + 1])) != nil else { return nil }
        return String(parts[i + 1]).lowercased()
    }

    public static func path(projectsRoot: String, cwd: String, uuid: String) -> String {
        "\(projectsRoot)/\(projectSlug(cwd: cwd))/\(uuid).jsonl"
    }

    /// Model id of the last main-loop assistant message in a transcript tail.
    /// Skips sidechain (subagent) entries and synthetic error messages; a
    /// truncated first line simply fails JSON parsing and is skipped.
    public static func lastAssistantModel(tail: Data) -> String? {
        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  obj["isSidechain"] as? Bool != true,
                  let message = obj["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  !model.isEmpty, model != "<synthetic>"
            else { continue }
            return model
        }
        return nil
    }

    /// Last `maxBytes` of the file; nil if unreadable.
    public static func readTail(path: String, maxBytes: Int = 65_536) -> Data? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return nil }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: offset)
        return try? fh.readToEnd()
    }
}
