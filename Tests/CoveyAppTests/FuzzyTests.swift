import XCTest
@testable import covey
import CoveyKit

final class FuzzyTests: XCTestCase {
    func testFilterRecentsMatchesNameAndDir() {
        let recents = [
            RecentSession(name: "api-fix", dir: "/Users/x/work/backend", agent: "claude"),
            RecentSession(name: "notes", dir: "/Users/x/pets/covey", agent: "zsh"),
        ]
        XCTAssertEqual(filterRecents(recents, filter: "").map(\.name),
                       ["api-fix", "notes"])                      // empty -> as is
        XCTAssertEqual(filterRecents(recents, filter: "apfx").map(\.name),
                       ["api-fix"])                               // fuzzy by name
        XCTAssertEqual(filterRecents(recents, filter: "covey").map(\.name),
                       ["notes"])                                 // by dir
        XCTAssertTrue(filterRecents(recents, filter: "zzz").isEmpty)
    }

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
