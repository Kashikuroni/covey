import Foundation
import CoveyKit

/// Итог одного poll-а Codex-вотчера. Только агрегаты: без путей, ID, cwd и
/// содержимого rollout-ов.
public struct CodexWatcherReport: Equatable, Sendable {
    public var bytesRead: Int
    public var filesRead: Int
    public var backfillRemaining: Bool
    public var stats: CodexUsageParseStats

    public init(bytesRead: Int = 0, filesRead: Int = 0,
                backfillRemaining: Bool = false,
                stats: CodexUsageParseStats = CodexUsageParseStats()) {
        self.bytesRead = bytesRead; self.filesRead = filesRead
        self.backfillRemaining = backfillRemaining; self.stats = stats
    }
}

enum CodexWatchError: Error, Equatable { case readFailed }

/// Инкрементальный обход всех Codex rollout-ов `~/.codex/sessions`.
/// Backfill: сегодняшние и семь предыдущих локальных дней, плюс любые
/// активные файлы (mtime ≤ 10 минут) и файлы с сохранённым курсором.
/// Бюджет чтения — 8 MiB на poll; курсор двигается только через последний
/// полный `\n`, поэтому partial tail читается ровно один раз. Truncation
/// (размер стал меньше offset) сбрасывает живые вёдра сессии и перечитывает
/// файл с нуля. Исключённые внешние файлы не получают курсора — повторное
/// включение backfill-ит всю доступную историю.
///
/// Source-level сбои чтения — throwable (ledger ruling): владелец хранит
/// последнюю хорошую analytics-снимок; битые отдельные строки остаются
/// счётчиками `stats`.
public final class CodexTranscriptWatcher {
    private let sessionsRoot: String
    private let aggregator: TokenAggregator
    private let store: QuotaSampleStore
    private let includeExternal: Bool
    private let maxBytesPerPoll: Int

    public init(sessionsRoot: String, aggregator: TokenAggregator,
                store: QuotaSampleStore, includeExternal: Bool,
                maxBytesPerPoll: Int = 8 * 1024 * 1024) {
        self.sessionsRoot = sessionsRoot
        self.aggregator = aggregator
        self.store = store
        self.includeExternal = includeExternal
        self.maxBytesPerPoll = maxBytesPerPoll
    }

    public func poll(now: Date,
                     sessions: [ForecastSessionIdentity]) throws -> CodexWatcherReport {
        var report = CodexWatcherReport()
        guard FileManager.default.fileExists(atPath: sessionsRoot) else {
            UsageLog.note("codex-watch", [("source", "missing"), ("files", "0")])
            return report
        }
        let from = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        var paths = Set(CodexTranscript.rolloutPaths(sessionsRoot: sessionsRoot,
                                                     from: from, through: now))
        paths.formUnion(store.codexCursors.keys)
        paths.formUnion(CodexTranscript.recentRolloutPaths(
            sessionsRoot: sessionsRoot,
            recentCutoff: now.addingTimeInterval(-600)))
        var budget = maxBytesPerPoll
        var pendingData = false
        var stoppedByBudget = false
        var readFailures = 0

        for path in paths.sorted() {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value else {
                store.removeCodexCursor(for: path)
                continue
            }
            // Сбой чтения ОДНОГО файла изолируется: остальные файлы poll-а
            // обрабатываются, курсор сбойного не двигается; summary-ошибка
            // бросается после обхода (владелец не замораживает конвейер).
            switch readFile(path: path, size: size, sessions: sessions, budget: &budget,
                            pendingData: &pendingData, report: &report) {
            case .read: break
            case .exhaustedBudget: stoppedByBudget = true
            case .failed: readFailures += 1
            }
            if stoppedByBudget { break }
        }

        aggregator.prune(now: now)
        store.setBuckets(aggregator.buckets)
        report.backfillRemaining = stoppedByBudget || (pendingData && budget <= 0)
        UsageLog.note("codex-watch", [
            ("files", "\(report.filesRead)"),
            ("bytes", "\(report.bytesRead)"),
            ("backfill", report.backfillRemaining ? "pending" : "done"),
            ("malformed", "\(report.stats.malformed)"),
            ("missingTs", "\(report.stats.missingTimestamp)"),
            ("missingModel", "\(report.stats.missingModel)"),
            ("invalidUsage", "\(report.stats.invalidUsage)"),
            ("readFailures", "\(readFailures)"),
        ])
        if readFailures > 0 { throw CodexWatchError.readFailed }
        return report
    }

    private enum ReadOutcome { case read, exhaustedBudget, failed }

    /// Чтение и разбор одного rollout-файла в рамках бюджета poll-а.
    private func readFile(path: String, size: UInt64, sessions: [ForecastSessionIdentity],
                          budget: inout Int, pendingData: inout Bool,
                          report: inout CodexWatcherReport) -> ReadOutcome {
        guard FileManager.default.isReadableFile(atPath: path) else { return .failed }
        guard let (metadata, sessionKey, matched) = identify(path: path, sessions: sessions)
        else { return .read }
        store.setSessionMetadata(
            ForecastSessionMetadata(source: .codex, cwd: metadata.cwd,
                                    external: !matched),
            for: sessionKey)
        if !matched && !includeExternal {
            // Метаданные сохранить можно, курсор — нельзя: иначе повторное
            // включение пропустит уже просмотренные события.
            return .read
        }
        var cursor = store.codexCursors[path]
        if let cur = cursor, size < cur.offset {
            aggregator.removeSession(sessionKey)
            cursor = nil
        }
        let offset = cursor?.offset ?? 0
        guard size > offset else { return .read }
        guard budget > 0 else { return .exhaustedBudget }
        guard let handle = FileHandle(forReadingAtPath: path) else { return .failed }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: min(Int(size - offset), budget)) else {
                return .failed
            }
            report.bytesRead += chunk.count
            budget -= chunk.count
            report.filesRead += 1
            if size - offset > chunk.count { pendingData = true }
            // Курсор двигается только через последний полный `\n`.
            let complete: Data
            if let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) {
                complete = Data(chunk[chunk.startIndex...lastNewline])
            } else {
                complete = Data()
            }
            guard !complete.isEmpty else { return .read }
            let result = CodexUsageScanner.parse(
                lines: complete.split(separator: UInt8(ascii: "\n")).map { Data($0) },
                sessionKey: sessionKey,
                initialModel: cursor?.model)
            for event in result.events { aggregator.ingest(event) }
            report.stats.formUnion(result.stats)
            store.setCodexCursor(CodexUsageCursor(
                offset: offset + UInt64(complete.count),
                model: result.model ?? cursor?.model,
                sessionKey: sessionKey,
                contexts: result.contexts.isEmpty ? cursor?.contexts ?? [] : result.contexts),
                for: path)
            return .read
        } catch {
            return .failed
        }
    }

    /// Метаданные rollout + ключ сессии + результат матчинга с Covey-сессией
    /// (Codex-агент, совпадение стандартизованного cwd, создание в пределах
    /// 120 секунд — те же правила, что у TraceMonitor).
    private func identify(path: String, sessions: [ForecastSessionIdentity])
        -> (metadata: CodexTranscript.Metadata, sessionKey: String, matched: Bool)? {
        guard let head = CodexTranscript.readHead(path: path),
              let metadata = CodexTranscript.metadata(head: head) else { return nil }
        let sessionKey = "codex:\(metadata.id)"
        let expectedCwd = URL(fileURLWithPath: metadata.cwd).standardizedFileURL.path
        let matched = sessions.contains { identity in
            guard CodexTranscript.isCodexAgent(identity.agent),
                  URL(fileURLWithPath: identity.cwd).standardizedFileURL.path == expectedCwd
            else { return false }
            return abs(metadata.timestamp.timeIntervalSince1970
                       - TimeInterval(identity.created)) <= 120
        }
        return (metadata, sessionKey, matched)
    }
}

extension CodexUsageParseStats {
    /// Суммирование счётчиков нескольких файлов одного poll-а.
    fileprivate mutating func formUnion(_ other: CodexUsageParseStats) {
        malformed += other.malformed
        missingTimestamp += other.missingTimestamp
        missingModel += other.missingModel
        invalidUsage += other.invalidUsage
    }
}
