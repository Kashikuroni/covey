import XCTest
@testable import CoveyKit

final class CoveyPathsTests: XCTestCase {
    func testDefaultRootIsDotCoveyUnderHome() {
        XCTAssertEqual(CoveyPaths.resolve(home: "/Users/x", env: [:]),
                       "/Users/x/.covey")
    }

    func testOverrideRelocatesWholeTree() {
        XCTAssertEqual(CoveyPaths.resolve(home: "/Users/x",
                                          env: ["COVEY_HOME": "/tmp/dev"]),
                       "/tmp/dev/.covey")
    }

    func testOverrideExpandsTilde() {
        XCTAssertEqual(CoveyPaths.resolve(home: "/Users/x",
                                          env: ["COVEY_HOME": "~/devbox"]),
                       NSHomeDirectory() + "/devbox/.covey")
    }

    func testBlankOverrideFallsBackToHome() {
        XCTAssertEqual(CoveyPaths.resolve(home: "/Users/x",
                                          env: ["COVEY_HOME": "  "]),
                       "/Users/x/.covey")
    }

    func testSocketLivesUnderStateRoot() {
        XCTAssertTrue(CoveyPaths.socketPath.hasSuffix("/.covey/coveyd.sock"))
    }
}
