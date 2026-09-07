import XCTest
@testable import covey
import CoveyKit

final class ProviderResolverTests: XCTestCase {
    func testBearerInjectsTokenFromReader() throws {
        let env = try ProviderResolver.resolve(
            profile: ProviderProfile.testProvider,
            readSecret: { _ in "KEY" })
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"], "KEY")
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "https://provider.example/anthropic")
    }
    func testApiKeySchemeUsesApiKeyVar() throws {
        let p = ProviderProfile(id: "x", label: "X", baseURL: "https://x", auth: .apiKey,
                                keychainAccount: "covey.provider.x")
        let env = try ProviderResolver.resolve(profile: p, readSecret: { _ in "K" })
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "K")
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
    }
    func testOmitsSecretForOauth() throws {
        let env = try ProviderResolver.resolve(
            profile: .anthropic, readSecret: { _ in fatalError("should not read") })
        XCTAssertEqual(env, [:])
    }
    func testThrowsWhenKeyNeededButAbsent() {
        XCTAssertThrowsError(
            try ProviderResolver.resolve(profile: .testProvider, readSecret: { _ in nil }))
    }
    func testThrowsWhenKeyEmpty() {
        XCTAssertThrowsError(
            try ProviderResolver.resolve(profile: .testProvider, readSecret: { _ in "" }))
    }
}
