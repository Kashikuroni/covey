import Foundation
import CoveyKit

/// Токены из транскриптов Claude Code. Парсер — чистый; вотчер хранит
/// инкрементальные офсеты (тот же приём, что TraceMonitor) в QuotaSampleStore.
public enum TokenUsageScanner {
    /// Реальные транскрипты пишут миллисекунды («…T11:00:00.123Z»); целые
    /// секунды — запасной формат. Дробный парсер первым: он же съел бы метку
    /// с дробной частью как nil, будь он вторым.
    private static let tsFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let tsWhole = ISO8601DateFormatter()

    /// Полные JSONL-строки → события. Хвост без `\n` — чужая недописанная
    /// строка: не учитывать и не двигать офсет за неё.
    public static func parse(_ data: Data, fallbackDate: Date) -> [TokenEvent] {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        var events: [TokenEvent] = []
        for line in data[..<lastNewline].split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let model = message["model"] as? String, !model.isEmpty, model != "<synthetic>",
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            func n(_ k: String) -> Double {
                (usage[k] as? NSNumber)?.doubleValue ?? 0
            }
            let input = n("input_tokens"), output = n("output_tokens")
            let cc = n("cache_creation_input_tokens"), cr = n("cache_read_input_tokens")
            guard input > 0 || output > 0 || cc > 0 || cr > 0 else { continue }
            let t = (obj["timestamp"] as? String).flatMap {
                tsFractional.date(from: $0) ?? tsWhole.date(from: $0)
            } ?? fallbackDate
            events.append(TokenEvent(t: t,
                                     sessionKey: (obj["sessionId"] as? String) ?? "unknown",
                                     model: model,
                                     isSidechain: obj["isSidechain"] as? Bool ?? false,
                                     input: input, output: output,
                                     cacheCreation: cc, cacheRead: cr))
        }
        return events
    }

    /// GLM-модель: сбор ведётся по всем провайдерам (claude/gpt идут в
    /// аналитику), но темпы GLM-квоты — только GLM-сессии.
    public static func isGLMModel(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.contains("glm") || m.contains("zai")
    }

    /// Реальный cwd проекта из транскрипта (первая попавшаяся запись): slug
    /// каталога в projectsRoot — путь, сплющенный в `-` (потеряны `/`, `.`,
    /// `_`), по нему путь не восстановить, а cwd в каждой записи есть.
    public static func firstCWD(in data: Data) -> String? {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return nil }
        for line in data[..<lastNewline].split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty
            else { continue }
            return cwd
        }
        return nil
    }

    /// Последние два assistant-хода каждой сессии в порции данных: токены
    /// контекста (input+cacheCreation+cacheRead) и метка времени — основа
    /// метрики роста контекста (этап 0). Свежий ход — первый.
    public static func lastContexts(in data: Data)
        -> [String: [(tokens: Double, t: Int64)]] {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return [:] }
        var out: [String: [(tokens: Double, t: Int64)]] = [:]
        for line in data[..<lastNewline].split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            func n(_ k: String) -> Double { (usage[k] as? NSNumber)?.doubleValue ?? 0 }
            let ctx = n("input_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens")
            let session = (obj["sessionId"] as? String) ?? "unknown"
            let t = (obj["timestamp"] as? String).flatMap {
                tsFractional.date(from: $0) ?? tsWhole.date(from: $0)
            }.map { Int64($0.timeIntervalSince1970 * 1000) }
            guard let t else { continue }
            out[session, default: []].append((ctx, t))
        }
        return out.mapValues { turns in
            turns.sorted { $0.t > $1.t }.prefix(2).map { ($0.tokens, $0.t) }
        }
    }

    /// Активные транскрипты: `projectsRoot/<slug>/<uuid>.jsonl` с mtime моложе cutoff.
    public static func activeFiles(projectsRoot: String, cutoff: Date, now: Date) -> [String] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsRoot) else { return [] }
        var files: [String] = []
        for slug in projects {
            let dirPath = projectsRoot + "/" + slug
            guard let names = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let path = dirPath + "/" + name
                guard let attr = try? fm.attributesOfItem(atPath: path),
                      let mtime = attr[.modificationDate] as? Date, mtime >= cutoff
                else { continue }
                files.append(path)
            }
        }
        return files.sorted()
    }
}

/// Инкрементальное чтение активных транскриптов в агрегатор. Офсеты переживают
/// рестарт через QuotaSampleStore; урезанный файл перечитывается с нуля.
/// Сессии передаются снимком на каждый poll (реестр не захватывается closures):
/// трекаются Covey-сессии любого провайдера и, при includeExternal, внешние
/// Claude Code CLI. Фильтрация GLM-моделей живёт в glmSessionRates, не здесь.
public final class TranscriptWatcher {
    private let projectsRoot: String
    private let aggregator: TokenAggregator
    private let store: QuotaSampleStore
    private let includeExternal: Bool

    public init(projectsRoot: String, aggregator: TokenAggregator, store: QuotaSampleStore,
                includeExternal: Bool) {
        self.projectsRoot = projectsRoot
        self.aggregator = aggregator
        self.store = store
        self.includeExternal = includeExternal
    }

    public func poll(now: Date, sessions: [ForecastSessionIdentity]) {
        let cutoff = now.addingTimeInterval(-600)   // активность: 10 мин (спека §3.2)
        let known = Set(sessions.compactMap(\.sourceID))
        func isTracked(_ path: String) -> Bool {
            known.contains(uuid(of: path)) || includeExternal
        }
        var paths = Set(TokenUsageScanner.activeFiles(projectsRoot: projectsRoot,
                                                      cutoff: cutoff, now: now).filter(isTracked))
        // Притихшие Covey-файлы с недочитанным хвостом дочитываем; внешние —
        // только пока активны (потеря их хвоста допустима: спека — неактивные
        // не участвуют в темпе, итоги окна критичны для Covey-сессий).
        for path in store.offsets.keys where known.contains(uuid(of: path)) {
            paths.insert(path)
        }
        for path in paths.sorted() { read(path) }
    }

    private func uuid(of path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
    }

    private func read(_ path: String) {
        guard let fh = FileHandle(forReadingAtPath: path),
              let size = (try? fh.seekToEnd()) else { return }
        defer { try? fh.close() }
        var offset = store.offsets[path] ?? 0
        if size < offset { offset = 0 }                  // урезание/ротация: заново
        guard size > offset else { return }
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd() else { return }
        let events = TokenUsageScanner.parse(data, fallbackDate: Date())
        for e in events { aggregator.ingest(e) }
        if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
            store.setOffset(path, offset + UInt64(lastNewline + 1))
        }
        // cwd проекта: снимаем один раз на slug; в хвосте его может не быть —
        // снимется на следующем чтении, у свежего файла он есть с первой порции.
        let slug = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        if store.cwds[slug] == nil, let cwd = TokenUsageScanner.firstCWD(in: data) {
            store.setCWD(slug, cwd: cwd)
        }
        // Контекст сессий (этап 0): последние два хода каждой сессии порции.
        // Не-GLM сессии в rates/ledger не попадают (агрегатор отфильтрован),
        // их записи контекста протухнут и выпадут 14-дневным пруном.
        let contexts = TokenUsageScanner.lastContexts(in: data)
        if !contexts.isEmpty {
            store.upsertLastContext(contexts.mapValues { turns in
                LastContextRecord(tokens: turns[0].tokens, t: turns[0].t,
                                  deltaPerTurn: turns.count > 1
                                      ? turns[0].tokens - turns[1].tokens : nil)
            })
        }
    }
}
