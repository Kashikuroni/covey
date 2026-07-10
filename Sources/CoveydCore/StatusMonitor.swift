import Foundation
import CoveyKit

/// Periodically derives every session's status from its visible screen and
/// reports transitions. Mirrors the 1.5 s poller of the Rust desktop app,
/// but lives in the daemon. All state is confined to the serial `queue`.
public final class StatusMonitor {
    /// Fires only when a session's status differs from the previous tick.
    public var onStatusChanged: ((String, Status) -> Void)?

    private let snapshot: () -> [String: String]
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "covey.status")
    private var timer: DispatchSourceTimer?
    private var prevHash: [String: Int] = [:]
    private var prevStatus: [String: Status] = [:]
    private var prevPrompt: [String: [String]] = [:]
    /// Consecutive ticks a live prompt has parsed empty. A single empty frame
    /// is a transient repaint (Claude redraws its boxed prompt mid-render);
    /// only drop the `.waiting` status once the prompt is gone for `clearGrace`
    /// ticks in a row.
    private var emptyStreak: [String: Int] = [:]
    private let clearGrace = 2

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
        var newEmptyStreak: [String: Int] = [:]
        for (name, content) in screens {
            let hash = StatusInference.contentHash(content)
            let parsed = StatusInference.parsePrompt(content)
            // Debounce a flicker to empty: hold the previous prompt for a few
            // ticks so a single garbled repaint frame does not flip `.waiting`
            // off. A genuinely answered prompt clears after `clearGrace`.
            var prompt = parsed
            let prev = prevPrompt[name] ?? []
            if parsed.isEmpty && !prev.isEmpty {
                let streak = (emptyStreak[name] ?? 0) + 1
                if streak < clearGrace {
                    prompt = prev
                    newEmptyStreak[name] = streak
                }
            }
            // `.waiting` is driven by the selection box, detected via a footer
            // marker OR parsed options — robust even when option parsing misses.
            let hasBox = !prompt.isEmpty
                || StatusInference.promptMarkers.contains { content.contains($0) }
            let status = StatusInference.deriveStatus(
                content: content,
                prevHash: prevHash[name],
                currentHash: hash,
                hasPrompt: hasBox
            )
            newHash[name] = hash
            newStatus[name] = status
            newPrompt[name] = prompt
            if prevStatus[name] != status {
                onStatusChanged?(name, status)
            }
        }
        // Replacing the maps wholesale prunes removed sessions.
        prevHash = newHash
        prevStatus = newStatus
        prevPrompt = newPrompt
        emptyStreak = newEmptyStreak
    }
}
