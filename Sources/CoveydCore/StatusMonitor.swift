import Foundation
import CoveyKit

/// Periodically derives every session's status from its visible screen and
/// reports transitions. Mirrors the 1.5 s poller of the Rust desktop app,
/// but lives in the daemon. All state is confined to the serial `queue`.
public final class StatusMonitor {
    /// Fires only when a session's status differs from the previous tick.
    public var onStatusChanged: ((String, Status) -> Void)?
    /// Fires when a session's detected prompt options change (empty = gone).
    public var onPromptChanged: ((String, [String]) -> Void)?

    private let snapshot: () -> [String: String]
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "covey.status")
    private var timer: DispatchSourceTimer?
    private var prevHash: [String: Int] = [:]
    private var prevStatus: [String: Status] = [:]
    private var prevPrompt: [String: [String]] = [:]

    public init(
        interval: TimeInterval = 1.5,
        snapshot: @escaping () -> [String: String]
    ) {
        self.interval = interval
        self.snapshot = snapshot
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.tickBody() }
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// One inference pass. The timer calls this; tests call it directly.
    public func tick() {
        queue.sync { tickBody() }
    }

    public func currentStatuses() -> [String: Status] {
        queue.sync { prevStatus }
    }

    // MARK: - private (on `queue`)

    private func tickBody() {
        let screens = snapshot()
        var newHash: [String: Int] = [:]
        var newStatus: [String: Status] = [:]
        var newPrompt: [String: [String]] = [:]
        for (name, content) in screens {
            let hash = StatusInference.contentHash(content)
            let prompt = StatusInference.parsePrompt(content)
            let status = StatusInference.deriveStatus(
                content: content,
                prevHash: prevHash[name],
                currentHash: hash,
                hasPrompt: !prompt.isEmpty
            )
            newHash[name] = hash
            newStatus[name] = status
            newPrompt[name] = prompt
            if prevStatus[name] != status {
                onStatusChanged?(name, status)
            }
            if prevPrompt[name, default: []] != prompt {
                onPromptChanged?(name, prompt)
            }
        }
        // Sessions that vanished while showing a prompt must clear it.
        for (name, options) in prevPrompt where newPrompt[name] == nil && !options.isEmpty {
            onPromptChanged?(name, [])
        }
        // Replacing the maps wholesale prunes removed sessions.
        prevHash = newHash
        prevStatus = newStatus
        prevPrompt = newPrompt
    }
}
