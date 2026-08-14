import XCTest
import SwiftUI
@testable import covey

final class TokensTests: XCTestCase {
    func testDarkPortMatchesAyuMirage() {
        XCTAssertEqual(Tokens.dark.bg, Color(hex: 0x1F2430))
        XCTAssertEqual(Tokens.dark.surface, Color(hex: 0x181C26))
        XCTAssertEqual(Tokens.dark.card, Color(hex: 0x242936))
        XCTAssertEqual(Tokens.dark.termBg, Color(hex: 0x181C26))
        XCTAssertEqual(Tokens.dark.t1, Color(hex: 0xCCCAC2))
        XCTAssertEqual(Tokens.dark.run, Color(hex: 0xFFA659))
        XCTAssertEqual(Tokens.dark.wait, Color(hex: 0xFFCD66))
        XCTAssertEqual(Tokens.dark.accent, Color(hex: 0xFFCC66))
    }

    func testLightPortMatchesAyuLight() {
        XCTAssertEqual(Tokens.light.bg, Color(hex: 0xF8F9FA))
        XCTAssertEqual(Tokens.light.surface, Color(hex: 0xEBEEF0))
        XCTAssertEqual(Tokens.light.card, Color(hex: 0xFCFCFC))
        XCTAssertEqual(Tokens.light.termBg, Color(hex: 0xEBEEF0))
        XCTAssertEqual(Tokens.light.run, Color(hex: 0xFA8532))
        XCTAssertEqual(Tokens.light.accent, Color(hex: 0xF29718))
    }

    func testGlmBrandMatchesOtherAgentBrands() {
        // Brand marks are a single neutral grey shared across all agents
        // (claudeBrand == codexBrand today) — glm follows the same tone.
        XCTAssertEqual(Tokens.dark.glmBrand, Tokens.dark.codexBrand)
        XCTAssertEqual(Tokens.light.glmBrand, Tokens.light.codexBrand)
    }

    func testThemeSelectionAndConstants() {
        XCTAssertEqual(Tokens(Theme(raw: "dark")).bg, Tokens.dark.bg)
        XCTAssertEqual(Tokens(Theme(raw: "light")).bg, Tokens.light.bg)
        XCTAssertEqual(Tokens.r, 6)
        XCTAssertEqual(Tokens.rSm, 4)
        XCTAssertEqual(Tokens.rLg, 10)
    }
}
