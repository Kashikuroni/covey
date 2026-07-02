import XCTest
@testable import covey

final class CredentialsTests: XCTestCase {
    func testExtractsToken() {
        let c = credentialsFromJSON(#"{"claudeAiOauth": {"accessToken": "sk-abc", "refreshToken": "x"}}"#)
        XCTAssertEqual(c?.accessToken, "sk-abc")
        XCTAssertNil(c?.expiresAtMs)
    }

    func testExtractsExpiry() {
        let c = credentialsFromJSON(#"{"claudeAiOauth": {"accessToken": "tok", "expiresAt": 1780000000000}}"#)
        XCTAssertEqual(c?.expiresAtMs, 1780000000000)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(credentialsFromJSON("not json"))
        XCTAssertNil(credentialsFromJSON(#"{"other": 1}"#))
    }

    func testIsExpired() {
        XCTAssertTrue(RawCredentials(accessToken: "t", expiresAtMs: 1).isExpired)          // 1970
        XCTAssertFalse(RawCredentials(accessToken: "t", expiresAtMs: nil).isExpired)       // unknown -> not expired
    }
}
