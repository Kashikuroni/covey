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
        t.schedule(deadline: .now() + 1, repeating: interval)
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

    private func tickBody() {
        var next: [String: GitInfo?] = [:]
        for (name, dir) in snapshot() {
            let info = GitOps.readGitInfo(dir)
            next[name] = info
            if prev[name] != info {
                onGitChanged?(name, info)
            }
        }
        prev = next   // wholesale replacement prunes removed sessions
    }
}
