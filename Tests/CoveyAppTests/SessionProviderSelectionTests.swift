import XCTest
import CoveyKit
@testable import covey

final class SessionProviderSelectionTests: XCTestCase {
    func testEveryNewClaudeSelectionDefaultsToAnthropic() {
        XCTAssertEqual(SessionProviderSelection.defaultClaudeProviderId, "anthropic")
    }

    func testProviderChoiceIsVisibleOnlyForExactClaudePreset() {
        XCTAssertTrue(SessionProviderSelection.providerChoiceIsVisible(agent: "claude"))
        XCTAssertFalse(SessionProviderSelection.providerChoiceIsVisible(agent: "claude --model opus"))
        XCTAssertFalse(SessionProviderSelection.providerChoiceIsVisible(agent: "codex"))
        XCTAssertFalse(SessionProviderSelection.providerChoiceIsVisible(agent: ""))
    }

    func testEffectiveProviderIsScopedToClaudeSession() {
        XCTAssertEqual(
            SessionProviderSelection.effectiveProviderId(agent: "claude", selectedId: "glm"),
            "glm"
        )
        XCTAssertNil(
            SessionProviderSelection.effectiveProviderId(agent: "codex", selectedId: "glm")
        )
    }

    func testCredentialProfilesExcludeProvidersThatNeedNoKey() {
        let profiles = SessionProviderSelection.credentialProfiles([.anthropic, .glm])
        XCTAssertEqual(profiles.map(\.id), ["glm"])
    }
}
