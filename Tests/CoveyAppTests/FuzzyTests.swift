import XCTest
@testable import covey
import CoveyKit

final class FuzzyTests: XCTestCase {
    func testSubsequenceMatches() {
        XCTAssertTrue(fuzzyMatch("cl", "claude"))
        XCTAssertTrue(fuzzyMatch("cd", "claude"))     // non-contiguous
        XCTAssertTrue(fuzzyMatch("claude", "claude"))
    }
    func testNonMatch() {
        XCTAssertFalse(fuzzyMatch("cx", "claude"))
        XCTAssertFalse(fuzzyMatch("dc", "claude"))    // order matters
    }
    func testEmptyPatternMatches() {
        XCTAssertTrue(fuzzyMatch("", "anything"))
    }
    func testCaseInsensitive() {
        XCTAssertTrue(fuzzyMatch("CL", "claude"))
        XCTAssertTrue(fuzzyMatch("cl", "CLAUDE"))
    }
}
