import Foundation
import CoveyKit

/// Polls each live session's git info (branch + shortstat) and reports
/// changes. Slower cadence than the status poller — git shells out per dir.
public final class GitMonitor {
    public var onGitChanged: ((String, GitInfo?) -> Void)?

    private let snapshot: () -> [(name: String, dir: String)]
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "covey.git")
    private var timer: DispatchSourceTimer?
    private var prev: [String: GitInfo?] = [:]

    public init(interval: TimeInterval = 5,
                snapshot: @escaping () -> [(name: String, dir: String)]) {
        self.interval = interval
        self.snapshot = snapshot
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        // First pass immediately: cards should not wait out the interval
        // after a daemon start.
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.tickBody() }
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// One pass; tests call this directly.
    public func tick() {
        queue.sync { tickBody() }
    }

    /// Drop the remembered reading for `name` so the next tick re-emits even
    /// an unchanged value. A restart wipes the registry's transient git info
    /// while the reading stays stable — without this the session never gets
    /// its git info back.
    public func forget(name: String) {
        queue.sync { prev[name] = nil }
    }

    /// Read one session now (async on the monitor queue) instead of waiting
    /// out the poll interval — create/restart call this so the card's git
    /// line appears immediately.
    public func poke(name: String, dir: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let info = GitOps.readGitInfo(dir)
            if (self.prev[name] ?? nil) != info {
                self.prev[name] = info
                self.onGitChanged?(name, info)
            }
        }
    }

    private func tickBody() {
        var next: [String: GitInfo?] = [:]
        for (name, dir) in snapshot() {
            let info = GitOps.readGitInfo(dir)
            next[name] = info
            // Normalize the missing-key case: an absent entry and a nil
            // reading are the same "no git info" — emitting a change there
            // races real events and wipes fresh info.
            if (prev[name] ?? nil) != info {
                onGitChanged?(name, info)
            }
        }
        prev = next   // wholesale replacement prunes removed sessions
    }
}
