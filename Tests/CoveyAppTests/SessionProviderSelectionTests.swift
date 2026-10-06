import XCTest
import CoveyKit
@testable import covey

final class SessionProviderSelectionTests: XCTestCase {
    func testCredentialProfilesExcludeProvidersThatNeedNoKey() {
        let profiles = SessionProviderSelection.credentialProfiles([.anthropic, .testProvider])
        XCTAssertEqual(profiles.map(\.id), ["custom"])
    }
}
