import XCTest
import CoveyKit
import CoveydCore
@testable import covey

@MainActor
final class ReviewLinkSettingsTests: XCTestCase {
    func testLinkSettingsDefaultPersistAndSurviveARestart() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let path = NSTemporaryDirectory() + "covey-links-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path)
        func makeModel() throws -> AppModel {
            let client = IPCClient(path: daemon.path)
            try client.connect()
            return AppModel(client: client, makeClient: {
                let next = IPCClient(path: daemon.path)
                try next.connect()
                return next
            }, store: store)
        }
        let model = try makeModel()
        await model.start()
        XCTAssertFalse(model.reviewLinks.showLinks, "Show links starts off")
        XCTAssertTrue(model.reviewLinks.linksOnFocus, "Links on focus starts on")
        XCTAssertTrue(model.settingsValues.linksOnFocus)

        model.reviewLinks.toggleShowLinks()
        store.flush()
        XCTAssertEqual(store.load().showLinks, true, "a toggle is saved at once")
        var values = model.settingsValues
        values.linksOnFocus = false
        model.applySettings(values)
        store.flush()
        XCTAssertEqual(store.load().linksOnFocus, false)

        let restored = try makeModel()
        await restored.start()
        XCTAssertTrue(restored.reviewLinks.showLinks)
        XCTAssertFalse(restored.reviewLinks.linksOnFocus)
        XCTAssertFalse(restored.settingsValues.linksOnFocus)
    }

    func testTheReviewSharesTheAppsLinkSettings() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        let reviews = ReviewFixture(model)
        await model.openReview(ReviewOpening(worktree: "/tmp", projectRoot: "/tmp", originSession: nil))
        let review = try XCTUnwrap(model.review)
        XCTAssertEqual(reviews.built.count, 1)
        XCTAssertIdentical(review.linkSettings, model.reviewLinks)

        await review.perform(.toggleLinks)
        XCTAssertTrue(model.reviewLinks.showLinks, "L in Review flips the app's setting")
        await review.perform(.toggleLinks)
        XCTAssertFalse(model.reviewLinks.showLinks)
    }
}
