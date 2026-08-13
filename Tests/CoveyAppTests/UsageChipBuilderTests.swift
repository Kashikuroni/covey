import XCTest
@testable import covey

final class UsageChipBuilderTests: XCTestCase {
    func testClaudeChipFromUsage() {
        let u = Usage(fiveHour: UsageWindow(utilization: 12, resetUnix: 1),
                      sevenDay: UsageWindow(utilization: 40, resetUnix: 2),
                      sevenDaySonnet: nil)
        let chip = claudeChip(usage: u, plan: "Max 5×")
        XCTAssertEqual(chip?.name, "Claude")
        XCTAssertEqual(chip?.plan, "Max 5×")
        XCTAssertEqual(chip?.windows.map(\.label), ["5h", "7d"])
    }

    func testClaudeChipNilWhenNoUsage() {
        XCTAssertNil(claudeChip(usage: nil, plan: "Max"))
    }

    func testPlanDroppedWhenItDuplicatesName() {
        // Unrecognized rate_limit_tier → planLabel fallback "Claude", which
        // would repeat the brand-name label. It must be suppressed.
        let u = Usage(fiveHour: UsageWindow(utilization: 10, resetUnix: 1),
                      sevenDay: nil, sevenDaySonnet: nil)
        XCTAssertNil(claudeChip(usage: u, plan: "Claude")?.plan)
        XCTAssertNil(claudeChip(usage: u, plan: "claude")?.plan)   // case-insensitive
        XCTAssertEqual(claudeChip(usage: u, plan: "Max 5×")?.plan, "Max 5×")
    }

    func testCodexChipFromSnapshot() {
        let snap = CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 8, resetUnix: 1)),
            secondary: LabeledWindow(label: "7d", window: UsageWindow(utilization: 22, resetUnix: 2)))
        let chip = codexChip(snapshot: snap, plan: "Pro")
        XCTAssertEqual(chip?.name, "Codex")
        XCTAssertEqual(chip?.plan, "Pro")
        XCTAssertEqual(chip?.windows.map(\.label), ["5h", "7d"])
    }

    func testCodexChipNilWhenNoSnapshot() {
        XCTAssertNil(codexChip(snapshot: nil, plan: "Pro"))
        XCTAssertNil(codexChip(snapshot: CodexRateLimitsSnapshot(primary: nil, secondary: nil),
                               plan: "Pro"))
    }

    func testGlmChipFromUsage() {
        let u = Usage(fiveHour: UsageWindow(utilization: 17, resetUnix: 1),
                      sevenDay: nil, sevenDaySonnet: nil)
        let chip = glmChip(usage: u)
        XCTAssertEqual(chip?.name, "GLM")
        XCTAssertNil(chip?.plan, "z.ai's quota endpoint carries no plan/tier name")
        XCTAssertEqual(chip?.windows.map(\.label), ["5h"])
    }

    func testGlmChipNilWhenNoUsage() {
        XCTAssertNil(glmChip(usage: nil))
    }
}
