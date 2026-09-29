import XCTest
import CoveyGit
import CoveyKit
@testable import CoveydCore

final class GitInfoSummaryTests: XCTestCase {
    func testSummaryMapsFieldForField() {
        let summary = WorkingTreeSummary(
            branch: "feat",
            unstaged: DiffTotals(files: 2, added: 5, removed: 1),
            staged: DiffTotals(files: 1, added: 3, removed: 0),
            untracked: 4)
        XCTAssertEqual(GitInfo(summary: summary), GitInfo(
            branch: "feat",
            unstaged: GitDiffSummary(files: 2, added: 5, removed: 1),
            staged: GitDiffSummary(files: 1, added: 3, removed: 0),
            untracked: 4))
    }
}
