import Foundation
import CoveyKit

/// Loads/saves `PersistedState` as JSON. Saves are debounced (repeated calls
/// coalesce into one write of the latest value) and atomic (`Data.write(.atomic)`
/// writes to a temp file then renames, so no partial file is ever observable).
public final class StateStore {
    private let url: URL
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "covey.state")
    private var timer: DispatchSourceTimer?
    private var pending: PersistedState?
    private var _writeCount = 0

    public init(path: String, debounce: TimeInterval = 0.5) {
        self.url = URL(fileURLWithPath: path)
        self.debounce = debounce
    }

    public func load() -> PersistedState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return PersistedState() }
        return state
    }

    public func save(_ state: PersistedState) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending = state
            self.timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + self.debounce)
            t.setEventHandler { [weak self] in self?.writePending() }
            self.timer = t
            t.resume()
        }
    }

    public func flush() {
        queue.sync {
            timer?.cancel()
            timer = nil
            writePending()
        }
    }

    public var writeCount: Int {
        queue.sync { _writeCount }
    }

    // MARK: - private (on `queue`)

    private func writePending() {
        timer = nil
        guard let state = pending else { return }
        pending = nil
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)   // temp + rename under the hood
            _writeCount += 1
        } catch {
            // best-effort persistence; a failed write must not crash the UI
        }
    }
}
