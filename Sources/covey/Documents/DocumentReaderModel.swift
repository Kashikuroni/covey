import Foundation
import Observation
import CoveyKit

@Observable @MainActor final class DocumentReaderModel {
    var context: DocumentContext
    private(set) var snapshot: DocumentFileSnapshot?
    private(set) var current: DocumentLocation?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var revision = 0
    var stateChanged: (() -> Void)?
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex + 1 < history.count }
    @ObservationIgnored private let loader: any DocumentFileLoading
    @ObservationIgnored private let watcher: any DocumentWatching
    @ObservationIgnored private var watchToken: DocumentWatchToken?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var history: [DocumentLocation] = []
    @ObservationIgnored private var historyIndex = -1
    @ObservationIgnored private var active = true
    init(context: DocumentContext, loader: any DocumentFileLoading = DocumentFileLoader(), watcher: any DocumentWatching = DocumentFileWatcher()) {
        self.context = context; self.loader = loader; self.watcher = watcher
    }
    func open(_ location: DocumentLocation) async {
        if historyIndex >= 0, let current { history[historyIndex] = current }
        if current != location {
            if historyIndex + 1 < history.count { history.removeSubrange((historyIndex + 1)..<history.count) }
            history.append(location)
            if history.count > 100 { history.removeFirst(history.count - 100) }
            historyIndex = history.count - 1
        }
        let changedFile = current?.path != location.path
        current = location
        if changedFile { snapshot = nil }
        active = true
        attachWatch()
        stateChanged?()
        await load()
    }
    func refresh() async { guard active, current != nil else { return }; await load() }
    func activate() async { active = true; attachWatch(); await refresh() }
    func goBack() async { await moveHistory(-1) }
    func goForward() async { await moveHistory(1) }
    private func moveHistory(_ delta: Int) async {
        let next = historyIndex + delta
        guard history.indices.contains(next) else { return }
        if let current { history[historyIndex] = current }
        historyIndex = next
        let location = history[next]
        if current?.path != location.path { snapshot = nil }
        current = location
        attachWatch()
        stateChanged?()
        await load()
    }
    func recordPosition(_ position: DocumentPosition) {
        guard current != nil else { return }
        current?.position = position
        current?.fragment = nil
        if history.indices.contains(historyIndex), let current { history[historyIndex] = current }
        stateChanged?()
    }
    private func load() async {
        guard let location = current else { return }
        generation += 1
        let request = generation
        loading = true
        do {
            let value = try await loader.load(path:location.path,context:context)
            guard request == generation, active else { return }
            snapshot = value; error = nil; loading = false; revision += 1
        } catch {
            guard request == generation, active else { return }
            self.error = error.localizedDescription; loading = false
        }
        stateChanged?()
    }
    private func attachWatch() {
        watchToken?.cancel(); watchToken = nil
        guard active, let path = current?.path else { return }
        watchToken = watcher.watch(path:path,context:context) { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
    }
    func stop() { active = false; generation += 1; loading = false; watchToken?.cancel(); watchToken = nil }
    deinit { watchToken?.cancel() }
}
