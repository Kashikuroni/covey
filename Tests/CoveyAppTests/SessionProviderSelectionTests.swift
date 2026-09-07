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
            SessionProviderSelection.effectiveProviderId(agent: "claude", selectedId: "custom"),
            "custom"
        )
        XCTAssertNil(
            SessionProviderSelection.effectiveProviderId(agent: "codex", selectedId: "custom")
        )
    }

    func testCredentialProfilesExcludeProvidersThatNeedNoKey() {
        let profiles = SessionProviderSelection.credentialProfiles([.anthropic, .testProvider])
        XCTAssertEqual(profiles.map(\.id), ["custom"])
    }
}
