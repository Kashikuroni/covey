import XCTest
@testable import covey

final class UsageChipBuilderTests: XCTestCase {
    // MARK: - GLM

    private var sampleQuota: GLMQuota {
        GLMQuota(plan: "max", limits: GLMLimits(
            fiveHours: GLMLimitWindow(total: 28000, used: 5695, remaining: 22304,
                                      usedPercent: 20, remainingPercent: 80,
                                      resetAt: 1_790_943_951_592),
            weekly: GLMLimitWindow(total: 140000, used: 5695, remaining: 134304,
                                   usedPercent: 4, remainingPercent: 96,
                                   resetAt: 1_791_529_507_983)))
    }

    func testGLMChipFromQuota() {
        let chip = glmChip(quota: sampleQuota)
        XCTAssertEqual(chip?.name, "GLM")
        XCTAssertEqual(chip?.plan, "Max")
        XCTAssertEqual(chip?.windows.map(\.label), ["5h", "7d"])
        XCTAssertEqual(chip?.windows.map(\.window.utilization), [20, 4])
        XCTAssertEqual(chip?.windows.map(\.window.resetUnix),
                       [1_790_943_951, 1_791_529_507], "reset_at ms becomes Unix seconds")
    }

    func testGLMChipNilWhenNoQuotaOrNoWindows() {
        XCTAssertNil(glmChip(quota: nil))
        XCTAssertNil(glmChip(quota: GLMQuota(plan: "max", limits: GLMLimits())))
    }

    // MARK: - header single-window pick

    /// Pinned moments of the 210 s cycle: the first 30 s blink 7d.
    private let blinkOn = Date(timeIntervalSince1970: 10)
    private let blinkOff = Date(timeIntervalSince1970: 100)

    func testWeeklyBlinkPhase() {
        XCTAssertTrue(weeklyBlinkActive(now: Date(timeIntervalSince1970: 0)))
        XCTAssertTrue(weeklyBlinkActive(now: Date(timeIntervalSince1970: 29)))
        XCTAssertFalse(weeklyBlinkActive(now: Date(timeIntervalSince1970: 30)))
        XCTAssertFalse(weeklyBlinkActive(now: Date(timeIntervalSince1970: 209)))
        XCTAssertTrue(weeklyBlinkActive(now: Date(timeIntervalSince1970: 210)),
                      "the 3-minute cycle wraps")
    }

    func testHeaderWindowShows5hByDefault() {
        let pick = headerWindow(fiveHour: UsageWindow(utilization: 40, resetUnix: 1),
                                sevenDay: UsageWindow(utilization: 90, resetUnix: 2),
                                blinkActive: false)
        XCTAssertEqual(pick.label, "5h")
        XCTAssertEqual(pick.window?.utilization, 40, "5h wins outside the blink")
    }

    func testHeaderWindowRed7dTakesOverDuringBlink() {
        let borderline = UsageWindow(utilization: 80, resetUnix: 1)
        XCTAssertEqual(headerWindow(fiveHour: UsageWindow(utilization: 10, resetUnix: 1),
                                     sevenDay: borderline, blinkActive: true).label,
                       "7d", "80% is red and takes the slot")
        XCTAssertEqual(headerWindow(fiveHour: UsageWindow(utilization: 10, resetUnix: 1),
                                     sevenDay: UsageWindow(utilization: 79, resetUnix: 1),
                                     blinkActive: true).label,
                       "5h", "79% is not red")
        XCTAssertEqual(headerWindow(fiveHour: UsageWindow(utilization: 10, resetUnix: 1),
                                     sevenDay: borderline, blinkActive: false).label,
                       "5h", "red 7d outside the blink phase stays hidden")
    }

    func testHeaderWindowLone7dIsPermanent() {
        let lone = headerWindow(fiveHour: nil,
                                sevenDay: UsageWindow(utilization: 45, resetUnix: 1),
                                blinkActive: false)
        XCTAssertEqual(lone.label, "7d")
        XCTAssertEqual(lone.window?.utilization, 45)
        let none = headerWindow(fiveHour: nil, sevenDay: nil, blinkActive: true)
        XCTAssertNil(none.window)
    }

    // MARK: - header segments

    private var twoWindowUsage: Usage {
        Usage(fiveHour: UsageWindow(utilization: 40, resetUnix: 1),
              sevenDay: UsageWindow(utilization: 91, resetUnix: 2),
              sevenDaySonnet: nil)
    }

    private var twoWindowCodex: CodexRateLimitsSnapshot {
        CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 8, resetUnix: 1)),
            secondary: LabeledWindow(label: "7d", window: UsageWindow(utilization: 18, resetUnix: 2)))
    }

    func testHeaderSegmentsShowOneWindowPerProvider() {
        let segs = headerSegments(usage: twoWindowUsage, usageError: nil,
                                  codexUsage: twoWindowCodex,
                                  glmQuota: sampleQuota, glmEnabled: true,
                                  now: blinkOff)
        XCTAssertEqual(segs.map(\.label), ["Claude", "Codex", "GLM"])
        XCTAssertEqual(segs.map(\.windowTag), ["5h", "5h", "5h"])
        XCTAssertEqual(segs.map(\.value), ["40%", "8%", "20%"])
    }

    func testHeaderSegmentsBlinkSwapsRed7dIntoTheSlot() {
        let hotCodex = CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 8, resetUnix: 1)),
            secondary: LabeledWindow(label: "7d", window: UsageWindow(utilization: 85, resetUnix: 2)))
        let segs = headerSegments(usage: twoWindowUsage, usageError: nil,
                                  codexUsage: hotCodex,
                                  glmQuota: sampleQuota, glmEnabled: true,
                                  now: blinkOn)
        XCTAssertEqual(segs.map(\.windowTag), ["7d", "7d", "5h"],
                       "red 7d takes over; GLM's calm 7d does not")
        XCTAssertEqual(segs.map(\.value), ["91%", "85%", "20%"])
        XCTAssertEqual(segs.map(\.level), [.err, .err, .ok])
    }

    func testHeaderSegmentsShowOnlyEnabledProviders() {
        let segs = headerSegments(usage: nil, usageError: nil, codexUsage: nil,
                                  glmQuota: sampleQuota, glmEnabled: false,
                                  claudeEnabled: false, codexEnabled: true)
        XCTAssertEqual(segs.map(\.label), ["Codex"], "disabled providers free their slots")

        let all = headerSegments(usage: nil, usageError: nil, codexUsage: nil,
                                 glmQuota: nil, glmEnabled: true,
                                 claudeEnabled: false, codexEnabled: false)
        XCTAssertEqual(all.map(\.label), ["GLM"])
    }

    func testHeaderSegmentsLone7dWindowIsAlwaysShown() {
        let weeklyOnly = GLMQuota(plan: "max", limits: GLMLimits(
            weekly: GLMLimitWindow(total: 140000, used: 5695, remaining: 134304,
                                   usedPercent: 45, remainingPercent: 55,
                                   resetAt: 1_791_529_507_983)))
        let segs = headerSegments(usage: nil, usageError: nil, codexUsage: nil,
                                  glmQuota: weeklyOnly, glmEnabled: true,
                                  now: blinkOff)
        XCTAssertEqual(segs.last?.windowTag, "7d")
        XCTAssertEqual(segs.last?.value, "45%")
    }

    func testHeaderSegmentsCodexExoticLabelsFallBackToMostUsed() {
        let exotic = CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "primary", window: UsageWindow(utilization: 9, resetUnix: 1)),
            secondary: nil)
        let segs = headerSegments(usage: nil, usageError: nil, codexUsage: exotic,
                                  now: blinkOff)
        XCTAssertEqual(segs[1].windowTag, nil)
        XCTAssertEqual(segs[1].value, "9%")
    }
}
