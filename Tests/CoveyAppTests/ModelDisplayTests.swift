import XCTest
@testable import covey

final class ModelDisplayTests: XCTestCase {
    func testKnownIdsFromSpec() {
        XCTAssertEqual(modelDisplayName("claude-fable-5"), "Fable 5")
        XCTAssertEqual(modelDisplayName("claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(modelDisplayName("claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(modelDisplayName("claude-haiku-4-5-20251001"), "Haiku 4.5")
    }

    func testUnknownIdDegradesGracefully() {
        XCTAssertEqual(modelDisplayName("claude-mythos-5-1"), "Mythos 5.1")
        XCTAssertEqual(modelDisplayName("gpt-6"), "Gpt 6")
        XCTAssertEqual(modelDisplayName("weird"), "Weird")
    }
}
