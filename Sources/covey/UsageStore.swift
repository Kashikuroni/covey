import Foundation
@_exported import CoveyKit

/// Observable client-side copy. Collection and provider settings belong to coveyd.
@MainActor @Observable
final class UsageStore {
    private(set) var snapshot = UsageSnapshot()
    private(set) var connectionError: String?
    private(set) var isAvailable = false
    private var lastRevision: UInt64?
    private let onPersist: () -> Void
    private let readMarkers: () -> [String: Int64]
    private let writeMarkers: ([String: Int64]) -> Void
    var alertSink: (([LimitAlert]) -> Void)?

    init(onPersist: @escaping () -> Void = {},
         readMarkers: @escaping () -> [String: Int64] = { [:] },
         writeMarkers: @escaping ([String: Int64]) -> Void = { _ in }) {
        self.onPersist = onPersist
        self.readMarkers = readMarkers
        self.writeMarkers = writeMarkers
    }

    func beginSubscription() {
        lastRevision = nil
        isAvailable = false
        connectionError = "Connecting to daemon limits…"
    }

    func failed(_ error: Error) {
        if case let IPCClientError.daemonError(code, message) = error, code == "usageSettingsFailed" {
            connectionError = message
            return // Keep connected controls available so saving can be retried.
        }
        isAvailable = false
        if case let IPCClientError.daemonError(code, _) = error,
           ["badRequest", "usageUnavailable"].contains(code) {
            connectionError = "This daemon does not support limits. Update coveyd when your terminal sessions can be safely stopped."
        } else {
            connectionError = "Limits unavailable: \(error). Showing last received data."
        }
    }

    func disconnected() {
        isAvailable = false
        connectionError = "Daemon disconnected. Showing last received data."
    }

    func apply(_ next: UsageSnapshot) {
        if let lastRevision, next.revision < lastRevision { return }
        connectionError = nil
        isAvailable = true
        guard lastRevision != next.revision else { return }
        lastRevision = next.revision
        snapshot = next
        if next.claudeUsageEnabled, next.usageError == nil, let usage = next.usage {
            notify(agent: "Claude", windows: [("5h", usage.fiveHour), ("7d", usage.sevenDay)])
        }
        if next.codexUsageEnabled, case .active = next.codexState, let usage = next.codexUsage {
            notify(agent: "Codex", windows: usage.windows.map { ($0.label, $0.window) })
        }
        if next.glmUsageEnabled, next.glmUsageError == nil, let chip = glmChip(quota: next.glmQuota) {
            notify(agent: "GLM", windows: chip.windows.map { ($0.label, $0.window) })
        }
    }

    private func notify(agent: String, windows: [(key: String, window: UsageWindow?)]) {
        let (alerts, marks) = limitAlerts(agent: agent, windows: windows,
                                         notified: readMarkers(), now: Date())
        if let alertSink { alertSink(alerts) }
        else { for alert in alerts { Notifier.post(alert) } }
        if marks != readMarkers() {
            writeMarkers(marks)
            onPersist()
        }
    }
}
