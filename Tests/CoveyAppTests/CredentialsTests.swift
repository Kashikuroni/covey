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

    func testEmptyTokenReturnsNil() {
        // A blanked keychain tombstone is valid JSON with an empty token; it
        // must not masquerade as a usable credential.
        XCTAssertNil(credentialsFromJSON(#"{"claudeAiOauth": {"accessToken": "", "expiresAt": 0}}"#))
    }

    func testIsExpired() {
        XCTAssertTrue(RawCredentials(accessToken: "t", expiresAtMs: 1).isExpired)          // 1970
        XCTAssertFalse(RawCredentials(accessToken: "t", expiresAtMs: nil).isExpired)       // unknown -> not expired
    }

    func testPickReturnsNilWhenBothAbsent() {
        XCTAssertNil(pickToken(fromFile: nil, fromKeychain: nil))
    }

    func testPickPrefersLiveKeychain() {
        let live = RawCredentials(accessToken: "live", expiresAtMs: nil)
        XCTAssertEqual(pickToken(fromFile: nil, fromKeychain: live), "live")
    }

    func testPickPrefersNonExpiredFileOverExpiredKeychain() {
        let fresh = RawCredentials(accessToken: "file", expiresAtMs: nil)
        let stale = RawCredentials(accessToken: "kc", expiresAtMs: 1)
        XCTAssertEqual(pickToken(fromFile: fresh, fromKeychain: stale), "file")
    }

    func testPickFallsBackToExpiredWhenOnlyOption() {
        let stale = RawCredentials(accessToken: "kc", expiresAtMs: 1)
        XCTAssertEqual(pickToken(fromFile: nil, fromKeychain: stale), "kc")
    }
}
