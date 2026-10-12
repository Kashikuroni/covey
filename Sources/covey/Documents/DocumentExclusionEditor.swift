import Foundation
import Observation
import CoveyKit

@Observable @MainActor final class DocumentExclusionEditor {
    let settings: DocumentExclusionSettings
    let context: DocumentContext?
    var scope: DocumentSettingsScope = .global
    private var drafts: [DocumentSettingsScope:String] = [:]
    private(set) var preview: DocumentCatalogSnapshot?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var detected: Set<DocumentPresetID> = [.common]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let scanner: any DocumentCatalogScanning
    @ObservationIgnored private var cachedConfiguration: DocumentExclusionConfiguration?
    @ObservationIgnored private var cachedDetected: Set<DocumentPresetID> = []
    @ObservationIgnored private var cachedRules: DocumentExclusionRules?
    init(settings: DocumentExclusionSettings, context: DocumentContext?, scanner: any DocumentCatalogScanning = ProjectDocumentCatalog()) {
        self.settings = settings; self.context = context; self.scanner = scanner
    }
    var savedScope: DocumentScopeExclusions {
        switch scope { case .global: return settings.configuration.global; case .project(let key): return settings.configuration.projects[key] ?? .init() }
    }
    var customRules: String {
        get { drafts[scope] ?? savedScope.customRules }
        set { drafts[scope] = newValue }
    }
    var isDirty: Bool { customRules != savedScope.customRules }
    var configuration: DocumentExclusionConfiguration {
        var result = settings.configuration
        switch scope {
        case .global: result.global.customRules = customRules
        case .project(let key): var value = result.projects[key] ?? .init(); value.customRules = customRules; result.projects[key] = value
        }
        return result
    }
    var diagnostics: [DocumentRuleDiagnostic] { DocumentExclusionDraft(configuration:configuration,projectKey:context?.projectKey).validate(detected:detected) }
    var compiled: DocumentExclusionRules? {
        let value = configuration
        if value != cachedConfiguration || detected != cachedDetected {
            cachedRules = try? .compile(configuration:value,projectKey:context?.projectKey ?? "",detected:detected)
            cachedConfiguration = value; cachedDetected = detected
        }
        return cachedRules
    }
    func update(_ change: (inout DocumentScopeExclusions) -> Void) {
        var result = settings.configuration, value = savedScope
        change(&value)
        switch scope { case .global: result.global = value; case .project(let key): result.projects[key] = value }
        settings.apply(result)
    }
    func applyRules() { guard diagnostics.isEmpty else { return }; settings.apply(configuration); drafts[scope] = nil }
    func revertRules() { drafts[scope] = nil }
    func resetPresets() {
        var draft = DocumentExclusionDraft(configuration:settings.configuration,projectKey:context?.projectKey)
        draft.resetPresets(scope:scope); settings.apply(draft.configuration)
    }
    func inheritProject() {
        guard case .project = scope else { return }
        var draft = DocumentExclusionDraft(configuration:settings.configuration,projectKey:context?.projectKey)
        draft.inheritProjectSettings(); settings.apply(draft.configuration); drafts[scope] = nil
    }
    func refreshPreview() async {
        generation += 1
        let request = generation
        preview = nil; error = nil; loading = false
        guard let context, diagnostics.isEmpty else { return }
        let configuration = configuration
        loading = true
        do {
            try await Task.sleep(for:.milliseconds(150))
            let result = try await scanner.scan(context:context,configuration:configuration)
            guard request == generation, !Task.isCancelled else { return }
            preview = result; detected = result.detected; loading = false
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription; loading = false
        }
    }
    func stop() { generation += 1; loading = false }
}
