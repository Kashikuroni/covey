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

    func testLimitsRowsAlwaysContainAllProvidersInOrder() {
        let rows = limitsRows(
            usage: nil, plan: nil, error: nil,
            codexUsage: nil, codexPlan: nil,
            claudeEnabled: true, codexEnabled: true
        )

        XCTAssertEqual(rows.map(\.provider), [.claude, .codex, .glm])
        XCTAssertEqual(rows.map(\.chip.name), ["Claude", "Codex", "GLM"])
        XCTAssertEqual(rows.map(\.emptyMessage), [
            "No usage data", "No usage data", "No usage data",
        ])
    }

    func testLimitsRowsUseProviderErrorOnlyForItsEmptyRow() {
        let rows = limitsRows(
            usage: nil, plan: nil, error: "Claude offline",
            codexUsage: nil, codexPlan: nil,
            claudeEnabled: true, codexEnabled: false,
            glmQuota: nil, glmEnabled: false, glmError: "401"
        )

        XCTAssertEqual(rows.map(\.emptyMessage), [
            "Claude offline", "No usage data", "HTTP 401",
        ])
        XCTAssertEqual(rows.map(\.enabled), [true, false, false])
    }

    func testLimitsRowsKeepUsageAndMarkLaterErrorAsStale() {
        let usage = Usage(fiveHour: UsageWindow(utilization: 17, resetUnix: 1),
                          sevenDay: nil, sevenDaySonnet: nil)
        let rows = limitsRows(
            usage: usage, plan: "Max", error: "network",
            codexUsage: nil, codexPlan: nil,
            claudeEnabled: true, codexEnabled: true
        )

        XCTAssertEqual(rows[0].chip.windows.map(\.label), ["5h"])
        XCTAssertTrue(rows[0].stale)
        XCTAssertNil(rows[0].emptyMessage)
    }

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

    func testGLMHeaderRowsListBothWindowsInOrder() {
        XCTAssertEqual(glmHeaderRows(sampleQuota),
                       [GLMHeaderRow(label: "5h", pct: 20), GLMHeaderRow(label: "7d", pct: 4)])
        XCTAssertEqual(glmHeaderRows(nil), [])

        let fiveOnly = GLMQuota(plan: "max", limits: GLMLimits(
            fiveHours: GLMLimitWindow(total: 28000, used: 21000, remaining: 7000,
                                      usedPercent: 75, remainingPercent: 25,
                                      resetAt: 1)))
        XCTAssertEqual(glmHeaderRows(fiveOnly), [GLMHeaderRow(label: "5h", pct: 75)])
    }

    func testGLMHeaderInlineValueJoinsBothWindows() {
        XCTAssertEqual(glmHeaderInlineValue([GLMHeaderRow(label: "5h", pct: 20),
                                             GLMHeaderRow(label: "7d", pct: 4)]), "20·4%")
        XCTAssertEqual(glmHeaderInlineValue([GLMHeaderRow(label: "5h", pct: 75)]), "75%")
        XCTAssertNil(glmHeaderInlineValue([]))
    }

    func testGLMHeaderLevelIsTheWorstWindow() {
        XCTAssertEqual(glmHeaderLevel([GLMHeaderRow(label: "5h", pct: 8),
                                       GLMHeaderRow(label: "7d", pct: 85)]), .err)
        XCTAssertEqual(glmHeaderLevel([GLMHeaderRow(label: "5h", pct: 55),
                                       GLMHeaderRow(label: "7d", pct: 4)]), .warn)
        XCTAssertEqual(glmHeaderLevel([GLMHeaderRow(label: "5h", pct: 20),
                                       GLMHeaderRow(label: "7d", pct: 4)]), .ok)
        XCTAssertNil(glmHeaderLevel([]))
    }

    func testHeaderSegmentsGLMShowsBothWindowsWithWorstLevel() {
        let hot = GLMQuota(plan: "max", limits: GLMLimits(
            fiveHours: GLMLimitWindow(total: 100, used: 90, remaining: 10,
                                      usedPercent: 90, remainingPercent: 10, resetAt: 1),
            weekly: GLMLimitWindow(total: 1000, used: 100, remaining: 900,
                                   usedPercent: 10, remainingPercent: 90, resetAt: 2)))
        let segs = headerSegments(usage: nil, usageError: nil, codexUsage: nil,
                                  glmQuota: hot, glmEnabled: true)
        XCTAssertEqual(segs.last?.label, "GLM")
        XCTAssertEqual(segs.last?.value, "90·10%")
        XCTAssertEqual(segs.last?.level, .err)
    }

    func testHeaderSegmentsIncludeGLMOnlyWhenEnabled() {
        let segments = headerSegments(usage: nil, usageError: nil, codexUsage: nil,
                                      glmQuota: sampleQuota, glmEnabled: true)
        XCTAssertEqual(segments.map(\.label), ["Claude", "Codex", "GLM"])
        XCTAssertEqual(segments.map(\.value), ["—", "—", "20·4%"])
        XCTAssertEqual(segments.map(\.level), [nil, nil, .ok])

        let disabled = headerSegments(usage: nil, usageError: nil, codexUsage: nil,
                                      glmQuota: sampleQuota, glmEnabled: false)
        XCTAssertEqual(disabled.map(\.label), ["Claude", "Codex"], "a disabled provider frees its slot")
    }

    func testGLMErrorTextMapsShortCodes() {
        XCTAssertEqual(glmErrorText(nil), "No usage data")
        XCTAssertEqual(glmErrorText("no auth"), "API key not set — add it in the limits window")
        XCTAssertEqual(glmErrorText("net"), "Network error")
        XCTAssertEqual(glmErrorText("parse"), "Unexpected response")
        XCTAssertEqual(glmErrorText("401"), "HTTP 401")
        XCTAssertEqual(glmErrorText("weird"), "weird")
    }

    func testGLMKeyRowLabelFollowsSpec() {
        func label(_ status: ProviderKeyStatus, _ valid: Bool) -> (text: String, action: String) {
            glmKeyRowLabel(status: status, valid: valid)
        }
        // Key present + limits arriving → valid | edit.
        XCTAssertEqual(label(.set, true).text, "api key — valid")
        XCTAssertEqual(label(.set, true).action, "edit")
        // Key present but fetch failing → invalid | edit (update the key).
        XCTAssertEqual(label(.set, false).text, "api key — invalid")
        XCTAssertEqual(label(.set, false).action, "edit")
        // No key at all → invalid | add.
        XCTAssertEqual(label(.missing, false).text, "api key — invalid")
        XCTAssertEqual(label(.missing, false).action, "add")
        XCTAssertEqual(label(.checking, false).text, "api key — checking…")
    }

    func testLimitsRowsGLMStaleKeepsWindows() {
        let rows = limitsRows(
            usage: nil, plan: nil, error: nil,
            codexUsage: nil, codexPlan: nil,
            claudeEnabled: true, codexEnabled: true,
            glmQuota: sampleQuota, glmEnabled: true, glmError: "net"
        )
        XCTAssertEqual(rows[2].chip.windows.count, 2)
        XCTAssertTrue(rows[2].stale)
        XCTAssertNil(rows[2].emptyMessage)
    }
}
