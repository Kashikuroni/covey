import XCTest
import SwiftUI
@testable import covey

/// Палитра столбчатого графика: провайдер по префиксу модели, оттенок ярче у
/// более мощной модели внутри провайдера, пользовательский цвет сильнее дефолта.
final class ModelPaletteTests: XCTestCase {
    func testProviderByModelPrefix() {
        XCTAssertEqual(ModelPalette.provider(of: "glm-4.6"), .glm)
        XCTAssertEqual(ModelPalette.provider(of: "glm-4.5-air"), .glm)
        XCTAssertEqual(ModelPalette.provider(of: "claude-opus-4-5"), .claude)
        XCTAssertEqual(ModelPalette.provider(of: "gpt-5"), .gpt)
        XCTAssertEqual(ModelPalette.provider(of: "codex-mini"), .gpt)
        XCTAssertEqual(ModelPalette.provider(of: "unknown-model"), .other)
    }

    func testPowerRankOrdersFlagshipFirst() {
        XCTAssertLessThan(ModelPalette.powerRank("claude-opus-4-5"),
                          ModelPalette.powerRank("claude-sonnet-4-5"))
        XCTAssertLessThan(ModelPalette.powerRank("claude-sonnet-4-5"),
                          ModelPalette.powerRank("claude-haiku-4-5"))
        XCTAssertLessThan(ModelPalette.powerRank("glm-4.6"),
                          ModelPalette.powerRank("glm-4.5-air"))
        XCTAssertLessThan(ModelPalette.powerRank("gpt-5-codex"),
                          ModelPalette.powerRank("gpt-4o-mini"))
    }

    func testDefaultColorBrighterForWeakerModel() {
        // «Ярче у мощной» = насыщеннее; ослабленная модель светлее базового тона.
        let flagship = ModelPalette.defaultColor(model: "claude-opus-4-5",
                                                 within: ["claude-haiku-4-5", "claude-opus-4-5"])
        let light = ModelPalette.defaultColor(model: "claude-haiku-4-5",
                                              within: ["claude-haiku-4-5", "claude-opus-4-5"])
        XCTAssertNotEqual(flagship, light)
        // светлее = выше суммарная яркость каналов
        let brightness: (Color) -> Double = { c in
            let ns = NSColor(c)
            return Double(ns.redComponent + ns.greenComponent + ns.blueComponent)
        }
        XCTAssertGreaterThan(brightness(light), brightness(flagship))
    }

    func testTierClassifiesFlagshipAndLight() {
        XCTAssertEqual(ModelPalette.tier(of: "claude-opus-4-5"), .top)
        XCTAssertEqual(ModelPalette.tier(of: "glm-4.6"), .top)
        XCTAssertEqual(ModelPalette.tier(of: "glm-4.5-air"), .light, "air-суффикс — облегчённая")
        XCTAssertEqual(ModelPalette.tier(of: "claude-haiku-4-5"), .light)
        XCTAssertEqual(ModelPalette.tier(of: "claude-sonnet-4-5"), .mid)
        XCTAssertEqual(ModelPalette.tier(of: "gpt-4o-mini"), .light)
        XCTAssertEqual(ModelPalette.tier(of: "some-unknown"), .other)
    }

    func testUserOverrideWinsOverDefault() {
        let custom = Color(red: 0.3, green: 0.3, blue: 0.3)
        XCTAssertEqual(ModelPalette.color(model: "glm-4.6", within: ["glm-4.6"],
                                          overrides: ["glm-4.6": custom]), custom)
    }
}
