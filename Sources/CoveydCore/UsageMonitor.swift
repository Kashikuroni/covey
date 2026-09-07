import Foundation
import CoveyKit

/// Daemon-owned collection and cache. No UI or notification delivery lives here.
@MainActor
public final class UsageMonitor {
    public private(set) var snapshot: UsageSnapshot
    public var onChange: ((UsageSnapshot) -> Void)?
    private let path: String?
    private var persistenceError: Error?
    private let fetchAccount: () async -> Account
    private let usageInterval: TimeInterval
    private let resolveCodex: () -> String?
    private var running = false
    private var pollers: [UsageProvider: Task<Void, Never>] = [:]
    private var generations: [UsageProvider: UInt64] = [:]
    private var requests: [UsageProvider: UInt64] = [:]
    private var codexServer: CodexAppServer?

    public init(path: String? = nil, legacyPath: String? = nil,
                fetchAccount: @escaping () async -> Account = UsageService.fetchAccount,
                usageInterval: TimeInterval = 60,
                resolveCodex: @escaping () -> String? = resolveCodexPath) {
        self.path = path
        self.fetchAccount = fetchAccount
        self.usageInterval = max(0.01, usageInterval)
        self.resolveCodex = resolveCodex
        var restored = UsageSnapshot()
        if let path, FileManager.default.fileExists(atPath: path) {
            do { restored = try JSONDecoder().decode(UsageSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: path))) }
            catch { persistenceError = error }
        } else if let legacyPath, FileManager.default.fileExists(atPath: legacyPath) {
            do {
                let legacy = try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: URL(fileURLWithPath: legacyPath)))
                restored.usage = legacy.claudeUsage?.live
                restored.plan = legacy.claudePlan
                restored.codexUsage = legacy.codexUsage?.live
                restored.codexPlan = legacy.codexPlan
                restored.claudeUsageEnabled = legacy.claudeUsageEnabled ?? true
                restored.codexUsageEnabled = legacy.codexUsageEnabled ?? true
            } catch { persistenceError = error }
        }
        restored.revision = 0
        restored.codexState = .stopped
        snapshot = restored
        // Import once even when the providers were all disabled in legacy state.
        if let path, !FileManager.default.fileExists(atPath: path), persistenceError == nil {
            do { try persist(restored) } catch { UsageLog.note("persistence", [("err", "\(error)")]) }
        }
        if let persistenceError { UsageLog.note("persistence", [("err", "\(persistenceError)")]) }
    }

    public func start() {
        guard !running else { return }
        running = true
        for provider in UsageProvider.allCases {
            pollers[provider] = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    if provider == .codex, self.snapshot.codexState != .unauthed {
                        if self.isEnabled(provider) { self.startCodexIfNeeded() }
                    } else {
                        await self.refresh(provider)
                    }
                    do { try await Task.sleep(nanoseconds: UInt64(self.usageInterval * 1_000_000_000)) }
                    catch { return }
                }
            }
        }
    }

    public func stop() {
        running = false
        for task in pollers.values { task.cancel() }
        pollers.removeAll()
        for provider in UsageProvider.allCases { generations[provider, default: 0] &+= 1 }
        stopCodex()
        if snapshot.codexState != .stopped { mutate { $0.codexState = .stopped } }
    }

    public func setEnabled(_ provider: UsageProvider, enabled: Bool) throws {
        guard isEnabled(provider) != enabled else { return }
        var next = snapshot
        switch provider {
        case .claude: next.claudeUsageEnabled = enabled
        case .codex: next.codexUsageEnabled = enabled; if !enabled { next.codexState = .stopped }
        }
        next.revision &+= 1
        try persist(next)
        generations[provider, default: 0] &+= 1
        snapshot = next
        onChange?(snapshot)
        if provider == .codex, !enabled { stopCodex() }
        if enabled, running { Task { [weak self] in await self?.refresh(provider) } }
    }

    public func refresh(_ provider: UsageProvider) async {
        guard isEnabled(provider) else { return }
        if provider == .codex {
            if case .active = snapshot.codexState {
                codexServer?.refreshRateLimits()
            } else {
                if snapshot.codexState == .unauthed { stopCodex() }
                startCodexIfNeeded()
            }
            return
        }
        let generation = generations[provider, default: 0]
        requests[provider, default: 0] &+= 1
        let request = requests[provider, default: 0]
        let account = await fetchAccount()
        guard !Task.isCancelled, isEnabled(provider), generations[provider, default: 0] == generation,
              requests[provider] == request else { return }
        mutate {
            if let usage = account.usage { $0.usage = usage }
            if let plan = account.plan { $0.plan = plan }
            $0.usageError = account.usageError
        }
    }

    public func ingestRateLimits(_ update: CodexRateLimitsSnapshot) {
        guard snapshot.codexUsageEnabled else { return }
        mutate { $0.codexUsage = mergeCodex(into: $0.codexUsage, update: update) }
    }

    public func setCodexState(_ state: CodexServerState) {
        guard snapshot.codexUsageEnabled else { return }
        if state == .stopped { stopCodex() }
        mutate {
            $0.codexState = state
            switch state {
            case .active(let account): $0.codexPlan = codexPlanLabel(account.planType)
            case .unauthed: $0.codexPlan = nil; $0.codexUsage = nil
            case .stopped, .starting: break
            }
        }
    }

    private func isEnabled(_ provider: UsageProvider) -> Bool {
        switch provider {
        case .claude: return snapshot.claudeUsageEnabled
        case .codex: return snapshot.codexUsageEnabled
        }
    }

    private func startCodexIfNeeded() {
        guard codexServer == nil, let path = resolveCodex() else { return }
        let server = CodexAppServer()
        let generation = generations[.codex, default: 0]
        server.onState = { [weak self, weak server] state in
            guard let self, let server, self.codexServer === server,
                  self.generations[.codex, default: 0] == generation else { return }
            self.setCodexState(state)
        }
        server.onRateLimits = { [weak self, weak server] update in
            guard let self, let server, self.codexServer === server,
                  self.generations[.codex, default: 0] == generation else { return }
            self.ingestRateLimits(update)
        }
        codexServer = server
        server.start(codexPath: path)
    }

    private func stopCodex() {
        let server = codexServer
        codexServer = nil
        server?.onState = nil
        server?.onRateLimits = nil
        server?.stop()
    }

    private func mutate(_ change: (inout UsageSnapshot) -> Void) {
        change(&snapshot)
        snapshot.revision &+= 1
        do { try persist(snapshot) }
        catch { UsageLog.note("persistence", [("err", "\(error)")]) }
        onChange?(snapshot)
    }

    private func persist(_ value: UsageSnapshot) throws {
        guard let path else { return }
        if let persistenceError { throw persistenceError }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
