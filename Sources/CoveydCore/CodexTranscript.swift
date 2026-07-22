import Foundation

/// Locating and parsing Codex rollout files and their configured fallback
/// model. Polling and live-session correlation live in ModelMonitor.
public enum CodexTranscript {
    public struct Metadata: Equatable {
        public let id: String
        public let cwd: String
        public let timestamp: Date
    }

    public static func isCodexAgent(_ agent: String) -> Bool {
        guard let command = agent.split(whereSeparator: { $0.isWhitespace }).first else {
            return false
        }
        return URL(fileURLWithPath: String(command)).lastPathComponent
            .lowercased().contains("codex")
    }

    public static func commandModel(_ agent: String) -> String? {
        let parts = agent.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for (index, part) in parts.enumerated() {
            if (part == "-m" || part == "--model"), parts.indices.contains(index + 1) {
                return nonEmpty(parts[index + 1])
            }
            if part.hasPrefix("--model=") {
                return nonEmpty(String(part.dropFirst("--model=".count)))
            }
        }
        return nil
    }

    public static func configuredModel(path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            if line.isEmpty || line.hasPrefix("#") { continue }
            let pair = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard pair.count == 2, pair[0] == "model" else { continue }
            let value = pair[1]
            guard value.first == "\"",
                  let closing = value.dropFirst().firstIndex(of: "\"") else { return nil }
            return nonEmpty(String(value[value.index(after: value.startIndex)..<closing]))
        }
        return nil
    }

    public static func metadata(head: Data) -> Metadata? {
        for line in head.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any],
                  let id = payload["id"] as? String,
                  let cwd = payload["cwd"] as? String,
                  let rawTimestamp = payload["timestamp"] as? String,
                  let timestamp = parseTimestamp(rawTimestamp) else { continue }
            return Metadata(id: id, cwd: cwd, timestamp: timestamp)
        }
        return nil
    }

    public static func lastTurnModel(tail: Data) -> String? {
        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "turn_context",
                  let payload = object["payload"] as? [String: Any],
                  let model = payload["model"] as? String else { continue }
            if let model = nonEmpty(model) { return model }
        }
        return nil
    }

    public static func rolloutPaths(sessionsRoot: String, created: Int64) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = Date(timeIntervalSince1970: TimeInterval(created))
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy/MM/dd"
        var result: [String] = []
        for offset in -1...1 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
            let directory = "\(sessionsRoot)/\(formatter.string(from: day))"
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                continue
            }
            result += names.filter { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
                .map { "\(directory)/\($0)" }
        }
        return result.sorted()
    }

    public static func readHead(path: String, maxBytes: Int = 65_536) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }

    public static func readTail(path: String, maxBytes: Int = 65_536) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        return try? handle.readToEnd()
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
