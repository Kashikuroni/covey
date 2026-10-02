import AppKit
import XCTest
@testable import covey

@MainActor
final class MenuBarColorTests: XCTestCase {
    func testPercentRunsKeepThresholdColorsAndNamesRemainNeutral() {
        for (value, color) in [(49.0, NSColor.systemGreen), (50, .systemOrange), (80, .systemRed)] {
            let text = menuBarLimitsAttributedTitle(
                usage: Usage(fiveHour: UsageWindow(utilization: value)), codexUsage: nil,
                glmQuota: nil, glmEnabled: true)
            let percentRange = (text.string as NSString).range(of: "\(Int(value))%")
            XCTAssertEqual(text.attribute(.foregroundColor, at: percentRange.location,
                                          effectiveRange: nil) as? NSColor, color)
            XCTAssertEqual(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                           .labelColor)
            XCTAssertTrue(text.string.hasSuffix("GPT —"))
        }
    }

    func testStatusImageRetainsColorAndCompactSize() {
        let text = menuBarLimitsAttributedTitle(
            usage: Usage(fiveHour: UsageWindow(utilization: 63)), codexUsage: nil,
                glmQuota: nil, glmEnabled: true)
        let image = menuBarLimitsImage(text)
        XCTAssertFalse(image.isTemplate)
        XCTAssertGreaterThan(image.size.width, 80)
        XCTAssertLessThan(image.size.width, 240)
        XCTAssertLessThanOrEqual(image.size.height, 22)
    }
}
