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

    /// Верхнеуровневый `timestamp` rollout-строки (ISO8601, допустимы
    /// дробные секунды). Общий для Trace- и Forecast-адаптеров, чтобы их
    /// трактовка upstream-схемы не расходилась.
    static func timestamp(_ object: [String: Any]) -> Date? {
        guard let raw = object["timestamp"] as? String else { return nil }
        return parseTimestamp(raw)
    }

    /// Сырые компоненты `last_token_usage` из `event_msg/token_count` —
    /// ровно как их отдаёт upstream, без нормализации: Trace хранит input
    /// как есть, вычитание cached делает только Forecast-сканер.
    struct RawTokenUsage: Equatable {
        var input: Double
        var cached: Double
        var output: Double
        var reasoning: Double
        var total: Double
        var contextWindow: Double?
    }

    static func rawTokenUsage(_ info: [String: Any]) -> RawTokenUsage? {
        guard let last = info["last_token_usage"] as? [String: Any] else { return nil }
        func num(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
        return RawTokenUsage(
            input: num(last, "input_tokens"),
            cached: num(last, "cached_input_tokens"),
            output: num(last, "output_tokens"),
            reasoning: num(last, "reasoning_output_tokens"),
            total: num(last, "total_tokens"),
            contextWindow: (info["model_context_window"] as? NSNumber)?.doubleValue)
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

    /// Явное перечисление локальных календарных дней [from…through]
    /// включительно — окно backfill прогнозного вотчера (сегодня и семь
    /// предыдущих дней).
    public static func rolloutPaths(sessionsRoot: String, from: Date, through: Date) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy/MM/dd"
        var result: [String] = []
        var day = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: through)
        while day <= last {
            let directory = "\(sessionsRoot)/\(formatter.string(from: day))"
            if let names = try? FileManager.default.contentsOfDirectory(atPath: directory) {
                result += names.filter { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
                    .map { "\(directory)/\($0)" }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result.sorted()
    }

    /// Все rollout-файлы в любом подкаталоге корня с mtime не старше
    /// `recentCutoff` — долго живущая сессия не теряется из-за того, что её
    /// каталог создания старше окна backfill.
    public static func recentRolloutPaths(sessionsRoot: String, recentCutoff: Date) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: sessionsRoot) else { return [] }
        var result: [String] = []
        for case let name as String in enumerator {
            // Enumerator выдаёт пути ОТНОСИТЕЛЬНО корня (включая подкаталоги
            // дат), поэтому префикс проверяется у имени файла, а не пути.
            let file = (name as NSString).lastPathComponent
            guard file.hasPrefix("rollout-"), file.hasSuffix(".jsonl") else { continue }
            let path = "\(sessionsRoot)/\(name)"
            if let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
               mtime >= recentCutoff {
                result.append(path)
            }
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
