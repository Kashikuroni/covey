import XCTest
import CoveyGit
@testable import covey

final class ReviewOpsPresentationTests: XCTestCase {
    func testPushButtonTitleCoversAllStates() {
        XCTAssertEqual(pushButtonTitle(upstream: nil, branch: "feat", pushing: false,
                                       upstreamPending: false), "Push")
        XCTAssertEqual(pushButtonTitle(upstream: nil, branch: "feat", pushing: false,
                                       upstreamPending: true), "Publish · origin/feat")
        XCTAssertEqual(pushButtonTitle(upstream: UpstreamInfo(remote: "origin", branch: "feat",
                                                              ahead: 3, behind: 0),
                                       branch: "feat", pushing: false, upstreamPending: false),
                       "Push ↑3")
        XCTAssertEqual(pushButtonTitle(upstream: UpstreamInfo(remote: "origin", branch: "feat",
                                                              ahead: 0, behind: 1),
                                       branch: "feat", pushing: true, upstreamPending: false),
                       "Pushing…")
    }

    func testCommitButtonTitle() {
        XCTAssertEqual(commitButtonTitle(committing: false), "Commit")
        XCTAssertEqual(commitButtonTitle(committing: true), "Committing…")
    }
}
