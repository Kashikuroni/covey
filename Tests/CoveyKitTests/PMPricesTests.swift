import XCTest
@testable import CoveyKit

final class PMPricesTests: XCTestCase {
    private let fixture: [PMPrice] = [
        PMPrice(match: "claude", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        PMPrice(match: "claude-opus", input: 15, output: 75, cacheRead: 1.875, cacheWrite: 18.75)
    ]

    func testLongestPrefixWins() {
        // "claude-opus-4.5" матчится обоими, но более длинный префикс точнее
        let c = PMPrices.cost(for: "claude-opus-4.5", prices: fixture,
                              input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)!
        XCTAssertEqual(c, 15, accuracy: 0.0001)
        let s = PMPrices.cost(for: "claude-sonnet-9", prices: fixture,
                              input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)!
        XCTAssertEqual(s, 3, accuracy: 0.0001)
    }

    func testUnknownModelHasNoPrice() {
        XCTAssertNil(PMPrices.cost(for: "mystery-model", prices: fixture,
                                   input: 100, output: 100, cacheRead: 0, cacheWrite: 0))
    }

    func testAllComponentsCounted() {
        let c = PMPrices.cost(for: "claude-opus", prices: fixture,
                              input: 2_000_000, output: 1_000_000,
                              cacheRead: 4_000_000, cacheWrite: 1_000_000)!
        // 2*15 + 1*75 + 4*1.875 + 1*18.75
        XCTAssertEqual(c, 30 + 75 + 7.5 + 18.75, accuracy: 0.0001)
    }

    func testBundleResourceLoads() throws {
        let prices = try XCTUnwrap(PMPrices.load(bundle: .module))
        XCTAssertTrue(prices.contains { $0.match == "claude-opus" })
    }
}
