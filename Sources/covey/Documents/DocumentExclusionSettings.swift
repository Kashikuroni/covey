import Foundation
import Observation
import CoveyKit

enum DocumentSettingsScope: Hashable { case global, project(String) }
struct DocumentExclusionDraft {
    var configuration: DocumentExclusionConfiguration
    let projectKey: String?
    func validate(detected: Set<DocumentPresetID>) -> [DocumentRuleDiagnostic] {
        var diagnostics: [DocumentRuleDiagnostic] = []
        for key in Set(configuration.projects.keys).union([projectKey ?? ""]) {
            do { _ = try DocumentExclusionRules.compile(configuration:configuration,projectKey:key,detected:detected) }
            catch let error as DocumentRuleCompileError {
                for diagnostic in error.diagnostics where !diagnostics.contains(diagnostic) { diagnostics.append(diagnostic) }
            } catch { diagnostics.append(.init(line:0,message:error.localizedDescription)) }
        }
        return diagnostics.sorted { $0.line < $1.line }
    }
    mutating func resetPresets(scope: DocumentSettingsScope) {
        switch scope {
        case .global: configuration.global = .init(customRules:configuration.global.customRules)
        case .project(let key): configuration.projects[key] = .init(customRules:configuration.projects[key]?.customRules ?? "")
        }
    }
    mutating func inheritProjectSettings() { if let projectKey { configuration.projects[projectKey] = nil } }
}
@Observable @MainActor final class DocumentExclusionSettings {
    private(set) var configuration: DocumentExclusionConfiguration
    var changed: ((Set<String>?) -> Void)?
    init(configuration: DocumentExclusionConfiguration = .init()) { self.configuration = configuration }
    func apply(_ configuration: DocumentExclusionConfiguration, notify: Bool = true) {
        guard configuration != self.configuration else { return }
        let old = self.configuration
        self.configuration = configuration
        let keys = Set(old.projects.keys).union(configuration.projects.keys).filter { old.projects[$0] != configuration.projects[$0] }
        if notify { changed?(old.global == configuration.global ? Set(keys) : nil) }
    }
}
