import XCTest
import CoveyKit
@testable import CoveydCore

final class GlmUsageServiceTests: XCTestCase {
    func testKeychainAccountMatchesRetiredProviderKey() {
        // Same item the retired GLM support used, so an existing stored key
        // keeps working without re-entry.
        XCTAssertEqual(GlmUsageService.keychainAccount, "covey.provider.glm")
    }

    func testQuotaRequestCarriesRawKeyWithoutBearerPrefix() throws {
        let req = try XCTUnwrap(GlmUsageService.quotaRequest(key: "zai-secret"))
        XCTAssertEqual(req.url?.absoluteString,
                       "https://api.z.ai/api/monitor/usage/quota/limit")
        // z.ai's monitor API takes the key verbatim — no Bearer scheme.
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "zai-secret")
        XCTAssertEqual(req.timeoutInterval, 10)
    }

    func testEmptyKeyShortCircuitsToNoAuth() async {
        let account = await GlmUsageService.fetchGLMAccount(key: "")
        XCTAssertNil(account.quota)
        XCTAssertEqual(account.error, "no auth")
    }
}
