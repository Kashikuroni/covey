import XCTest
import CoveyKit
@testable import covey

@MainActor final class DocumentExclusionSettingsTests: XCTestCase {
    func testSettingsSavePersistsAndInvalidDraftCannotCommit() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        var seed = PersistedState()
        seed.documentExclusions = .init(global:.init(customRules:"old/"))
        let (model,client) = try makeModel(daemon,seed:seed)
        defer { client.close() }
        await model.start()
        XCTAssertEqual(model.settingsValues.documentExclusions,seed.documentExclusions)
        var edited = model.settingsValues
        edited.documentExclusions.global.customRules = "new/"
        XCTAssertEqual(model.documentExclusionSettings.configuration,seed.documentExclusions)
        model.modal = .settings
        model.applySettings(edited)
        model.store.flush()
        XCTAssertEqual(model.store.load().documentExclusions,edited.documentExclusions)
        var invalid = edited
        invalid.documentExclusions.global.customRules = "[bad"
        model.modal = .settings
        model.applySettings(invalid)
        XCTAssertEqual(model.documentExclusionSettings.configuration,edited.documentExclusions)
        XCTAssertEqual(model.modal,.settings)
    }
    func testDraftCancelResetAndInheritance() {
        let initial = DocumentExclusionConfiguration(global:.init(useBuiltins:false,customRules:"global/"),projects:["p":.init(useBuiltins:true,presetOverrides:[.rust:false],customRules:"project/")])
        let live = DocumentExclusionSettings(configuration:initial)
        var draft = DocumentExclusionDraft(configuration:live.configuration,projectKey:"p")
        draft.resetPresets(scope:.project("p"))
        XCTAssertEqual(draft.configuration.projects["p"]?.customRules,"project/")
        XCTAssertNil(draft.configuration.projects["p"]?.useBuiltins)
        XCTAssertEqual(live.configuration,initial)
        draft.inheritProjectSettings()
        XCTAssertNil(draft.configuration.projects["p"])
        live.apply(draft.configuration)
        XCTAssertEqual(live.configuration,draft.configuration)
    }
    func testValidationAndAffectedScopes() {
        let live = DocumentExclusionSettings()
        var changes: [Set<String>?] = []
        live.changed = { changes.append($0) }
        live.apply(.init())
        XCTAssertTrue(changes.isEmpty)
        live.apply(.init(projects:["p":.init(useBuiltins:false)]))
        XCTAssertEqual(changes.first!,Set(["p"]))
        live.apply(.init(global:.init(useBuiltins:false)))
        XCTAssertNil(changes.last!)
        let draft = DocumentExclusionDraft(configuration:.init(global:.init(customRules:"[invalid")),projectKey:nil)
        XCTAssertEqual(draft.validate(detected:[.common]).first?.line,1)
    }
}
