import Foundation
import CoveyKit

/// Splits a byte stream into newline-delimited JSON chunks, retaining any
/// partial trailing line across pushes. Empty lines are dropped.
struct JSONLFramer {
    private var buffer = Data()
    mutating func push(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if !line.isEmpty { lines.append(Data(line)) }
        }
        return lines
    }
}

/// Codex app-server connection state.
enum CodexServerState: Equatable {
    case stopped
    case starting
    case unauthed                 // not a chatgpt account → no chip
    case active(CodexAccount)
}

/// `codex` absolute path via `command -v` under an enriched PATH (Finder-
/// launched GUI has only the bare system PATH). Returns nil if not installed.
func resolveCodexPath() -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "command -v -- codex"]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = enrichedPATH(env["PATH"], home: home)
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let path = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
}

/// Owns the `codex app-server` subprocess and the JSON-RPC handshake. Emits
/// rate-limit snapshots and account state via callbacks. Passive-only: never
/// initiates an interactive login; a non-chatgpt account ends the handshake
/// at `.unauthed`.
///
/// Rate limits are re-read on a timer, not just once: the codex backend's
/// `wham/usage` fetch can transiently fail (a single handshake read would then
/// leave the chip empty forever, since push `updated` events only arrive while
/// codex is actively used). The poll retries fast (6s) until the first snapshot
/// lands, then settles to 60s — push events still update in between.
@MainActor
final class CodexAppServer {
    var onRateLimits: ((CodexRateLimitsSnapshot) -> Void)?
    var onState: ((CodexServerState) -> Void)?

    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private var framer = JSONLFramer()
    private var started = false
    private var rateLimitsPoll: Task<Void, Never>?
    private var hasSnapshot = false

    // JSON-RPC request ids used during the handshake.
    private enum RPC: Int { case initialize = 1, account = 2, rateLimits = 3 }

    func start(codexPath: String) {
        guard !started else { return }
        started = true
        onState?(.starting)
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server"]
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = Pipe()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = enrichedPATH(env["PATH"], home: home)
        process.environment = env

        // Ordered delivery: readabilityHandler fires serially per fd, and
        // DispatchQueue.main.async is FIFO — so the stateful framer never sees
        // chunks out of order (a Task hop would not guarantee that).
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(data) } }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onState?(.stopped) } }
        }

        do {
            try process.run()
        } catch {
            onState?(.stopped)
            return
        }
        send(method: "initialize", id: RPC.initialize.rawValue, params: [
            "clientInfo": ["name": "covey", "title": "Covey", "version": "1.0.0"],
        ])
    }

    func stop() {
        rateLimitsPoll?.cancel()
        outPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    /// Re-read rate limits until the first snapshot lands (6s), then every 60s.
    private func startRateLimitsPolling() {
        rateLimitsPoll?.cancel()
        rateLimitsPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.send(method: "account/rateLimits/read", id: RPC.rateLimits.rawValue)
                let secs: UInt64 = self.hasSnapshot ? 60 : 6
                try? await Task.sleep(nanoseconds: secs * 1_000_000_000)
            }
        }
    }

    private func send(method: String, id: Int? = nil, params: [String: Any] = [:]) {
        var msg: [String: Any] = ["method": method, "params": params]
        if let id { msg["id"] = id }
        guard var data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        data.append(0x0A)   // JSONL
        try? inPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        for line in framer.push(data) {
            guard let obj = try? JSONSerialization.jsonObject(with: line),
                  let msg = obj as? [String: Any] else { continue }
            dispatch(msg)
        }
    }

    private func dispatch(_ msg: [String: Any]) {
        if let id = msg["id"] as? Int {
            // Error responses carry `id` too (no `result`); they fall through
            // to a nil parse and simply don't update — the poll retries.
            let result = msg["result"] as? [String: Any] ?? [:]
            switch RPC(rawValue: id) {
            case .initialize:
                send(method: "initialized")
                send(method: "account/read", id: RPC.account.rawValue,
                     params: ["refreshToken": true])
            case .account:
                guard let acc = parseCodexAccount(result) else { onState?(.stopped); return }
                guard acc.type == "chatgpt" else { onState?(.unauthed); return }
                onState?(.active(acc))
                startRateLimitsPolling()
            case .rateLimits:
                if let snap = parseCodexRateLimits(result) {
                    hasSnapshot = true
                    onRateLimits?(snap)
                }
            case .none:
                break
            }
            return
        }
        // Push notifications carry `method`, no `id`.
        if let method = msg["method"] as? String,
           method == "account/rateLimits/updated",
           let params = msg["params"] as? [String: Any],
           let snap = parseCodexRateLimits(params) {
            hasSnapshot = true
            onRateLimits?(snap)
        }
    }
}
