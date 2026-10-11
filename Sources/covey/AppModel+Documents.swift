import Foundation
import Observation
import CoveyKit

@Observable @MainActor final class DocumentPickerModel {
    let id = UUID()
    let viewID: ViewID
    let previousFocus: AppModel.Focus
    var context: DocumentContext?
    var state = DocumentPickerState()
    var snapshot: DocumentCatalogSnapshot?
    var loading = true
    var error: String?
    var exactPath = ""
    @ObservationIgnored var generation = 0
    init(viewID: ViewID, previousFocus: AppModel.Focus) { self.viewID = viewID; self.previousFocus = previousFocus }
}
extension AppModel {
    func openDocumentPicker() async {
        guard windowMode == .sessions, modal == nil, let id = activeViewID,
              let session = sessions.first(where:{ $0.name == focusedAgentPane }) ?? sessions.first(where:{ $0.name == selected }) else { return }
        let picker = DocumentPickerModel(viewID:id,previousFocus:focus)
        documentPicker = picker
        modal = .documentPicker
        let context: DocumentContext
        if let zone = views[id]?.documents { context = zone.context }
        else { context = await resolveDocumentContext(session).context }
        guard documentPicker === picker, modal == .documentPicker, views[id] != nil else { return }
        picker.context = context
        documentCatalogToken = DocumentCatalogWatcher().observe(root:context.root) { [weak self] in
            Task { @MainActor in await self?.rescanDocumentPicker() }
        }
        await rescanDocumentPicker()
    }
    func rescanDocumentPicker() async {
        guard let picker = documentPicker, let context = picker.context else { return }
        documentScanTask?.cancel()
        picker.generation += 1
        let generation = picker.generation
        let scanner = documentCatalog, configuration = documentExclusionSettings.configuration
        picker.loading = true
        let task = Task { [weak self, weak picker] in
            do {
                let snapshot = try await scanner.scan(context:context,configuration:configuration)
                guard let self, let picker, self.documentPicker === picker, picker.generation == generation, !Task.isCancelled else { return }
                picker.snapshot = snapshot; picker.loading = false; picker.error = nil
                picker.state.reconcileSelection(entries:snapshot.entries,recents:documentRecentPaths(root:context.root))
            } catch {
                guard let self, let picker, self.documentPicker === picker, picker.generation == generation, !Task.isCancelled else { return }
                picker.loading = false; picker.error = error.localizedDescription
            }
        }
        documentScanTask = task
        await task.value
    }
    func dismissDocumentPickerState() {
        documentScanTask?.cancel(); documentScanTask = nil
        documentCatalogToken?.cancel(); documentCatalogToken = nil
        if let picker = documentPicker { picker.generation += 1; setFocus(picker.previousFocus) }
        documentPicker = nil
    }
    func documentExclusionsDidChange(_ keys: Set<String>?) {
        guard let context = documentPicker?.context, keys == nil || keys!.contains(context.projectKey) else { return }
        Task { await rescanDocumentPicker() }
    }
    func openDocument(path: String, viewID: ViewID) async {
        guard views[viewID] != nil else { return }
        let context: DocumentContext
        if let existing = views[viewID]?.documents { context = existing.context }
        else if let picker = documentPicker, picker.viewID == viewID, let captured = picker.context { context = captured }
        else { return }
        do { _ = try DocumentLinkResolver.fileURL(path:path,context:context) }
        catch { documentPicker?.error = error.localizedDescription; return }
        mutateForView(viewID) { if $0.documents == nil { $0.documents = .init(context:context) } }
        if activeViewID != viewID {
            mutateForView(viewID) { $0.documents?.location = .init(path:path) }
            if documentPicker?.viewID == viewID { modal = nil }
            return
        }
        let reader = ensureDocumentReader(viewID:viewID,context:context)
        if documentPicker?.viewID == viewID { modal = nil }
        if activeViewID == viewID { sendTerminalCommand(.blur); setFocus(.documents) }
        await reader.open(.init(path:path))
        guard views[viewID] != nil, documentReaders[viewID] === reader else { return }
        if activeViewID != viewID { reader.stop() }
        if reader.error == nil, reader.current?.path == path {
            if let index = documentRecents.firstIndex(where:{ $0.root == context.root }) { documentRecents[index].opened(path) }
            else { var recent = PersistedDocumentRecents(root:context.root,paths:[]); recent.opened(path); documentRecents.append(recent) }
            persistWorkspaceViews()
        }
    }
    private func ensureDocumentReader(viewID: ViewID, context: DocumentContext) -> DocumentReaderModel {
        if let reader = documentReaders[viewID] { return reader }
        let reader = DocumentReaderModel(context:context)
        documentReaders[viewID] = reader
        reader.stateChanged = { [weak self, weak reader] in
            guard let self, let reader, self.views[viewID]?.documents != nil else { return }
            self.mutateForView(viewID,persist:false) { $0.documents?.location = reader.current }
            self.documentPersistTasks[viewID]?.cancel()
            self.documentPersistTasks[viewID] = Task { [weak self] in
                do { try await Task.sleep(for:.milliseconds(500)) } catch { return }
                self?.persistWorkspaceViews()
                self?.documentPersistTasks[viewID] = nil
            }
        }
        return reader
    }
    func syncDocumentActivity() async {
        guard windowMode == .sessions else { for reader in documentReaders.values { reader.stop() }; return }
        let active = activeViewID
        for (id,reader) in documentReaders where id != active { reader.stop() }
        guard let active, let zone = views[active]?.documents else { return }
        let reader = ensureDocumentReader(viewID:active,context:zone.context)
        if reader.current == nil, let location = zone.location { await reader.open(location) }
        else { await reader.activate() }
        if activeViewID != active { reader.stop() }
    }
    func discardDocumentState(viewID: ViewID) {
        documentReaders.removeValue(forKey:viewID)?.stop()
        documentPersistTasks.removeValue(forKey:viewID)?.cancel()
        if documentPicker?.viewID == viewID { modal = nil }
    }
    func closeDocuments(viewID: ViewID) {
        discardDocumentState(viewID:viewID)
        mutateForView(viewID) { $0.documents = nil }
        if activeViewID == viewID, focus == .documents {
            if let agent = focusedAgentPane, views[viewID]?.leaves.contains(agent) == true { focusPane(agent) }
            else if let agent = views[viewID]?.leaves.first { focusPane(agent) }
            else { setFocus(.sessions) }
        }
    }
    func setDocumentWidth(_ width: Double, viewID: ViewID) {
        guard width.isFinite else { return }
        mutateForView(viewID) { $0.documents?.width = max(0,width) }
    }
    func setDocumentSourceMode(_ source: Bool, viewID: ViewID) { mutateForView(viewID) { $0.documents?.sourceMode = source } }
    func documentRecentPaths(root: String) -> [String] { documentRecents.first(where:{ $0.root == root })?.paths ?? [] }
    func recordDocumentRecent(path: String, root: String) {
        if let index = documentRecents.firstIndex(where:{ $0.root == root }) { documentRecents[index].opened(path) }
        else { var recent = PersistedDocumentRecents(root:root,paths:[]); recent.opened(path); documentRecents.append(recent) }
        persistWorkspaceViews()
    }
}
