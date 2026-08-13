import XCTest
@testable import covey

final class SettingsStateTests: XCTestCase {
    private func values() -> SettingsValues {
        SettingsValues(theme: .dark, vimMode: true,
                       showSessions: true, showHeader: true, showFooter: false,
                       usagePlacement: .right,
                       claudeUsageEnabled: true, codexUsageEnabled: false,
                       glmUsageEnabled: true)
    }

    func testDraftStartsAtThemeWithSuppliedValues() {
        let draft = SettingsDraft(values: values())
        XCTAssertEqual(draft.values, values())
        XCTAssertEqual(draft.selectedRow, .theme)
    }

    func testJKWalkEveryRowAndClamp() {
        var draft = SettingsDraft(values: values())
        let down: [SettingsRow] = [
            .provider, .providerKey, .vimMode, .showSessions, .showHeader, .showFooter,
            .usagePlacement, .claudeUsage, .codexUsage, .glmUsage,
        ]
        for expected in down {
            XCTAssertNil(draft.handle(.moveDown))
            XCTAssertEqual(draft.selectedRow, expected)
        }
        XCTAssertNil(draft.handle(.moveDown))
        XCTAssertEqual(draft.selectedRow, .glmUsage)

        let up: [SettingsRow] = [
            .codexUsage, .claudeUsage, .usagePlacement, .showFooter,
            .showHeader, .showSessions, .vimMode, .providerKey, .provider, .theme,
        ]
        for expected in up {
            XCTAssertNil(draft.handle(.moveUp))
            XCTAssertEqual(draft.selectedRow, expected)
        }
        XCTAssertNil(draft.handle(.moveUp))
        XCTAssertEqual(draft.selectedRow, .theme)
    }

    func testHLWritesCheckboxValuesWithoutToggling() {
        var draft = SettingsDraft(values: values())
        let rows: [(SettingsRow, WritableKeyPath<SettingsValues, Bool>)] = [
            (.vimMode, \.vimMode),
            (.showSessions, \.showSessions),
            (.showHeader, \.showHeader),
            (.showFooter, \.showFooter),
            (.claudeUsage, \.claudeUsageEnabled),
            (.codexUsage, \.codexUsageEnabled),
            (.glmUsage, \.glmUsageEnabled),
        ]
        for (row, path) in rows {
            draft.selectedRow = row
            _ = draft.handle(.decrease)
            XCTAssertFalse(draft.values[keyPath: path], "h must write Off for \(row)")
            _ = draft.handle(.decrease)
            XCTAssertFalse(draft.values[keyPath: path], "repeated h must remain Off")
            _ = draft.handle(.increase)
            XCTAssertTrue(draft.values[keyPath: path], "l must write On for \(row)")
            _ = draft.handle(.increase)
            XCTAssertTrue(draft.values[keyPath: path], "repeated l must remain On")
        }
    }

    func testHLStepsFiniteChoicesAndClamps() {
        var draft = SettingsDraft(values: values())
        draft.selectedRow = .theme
        _ = draft.handle(.decrease)
        XCTAssertEqual(draft.values.theme, .dark)
        _ = draft.handle(.increase)
        XCTAssertEqual(draft.values.theme, .light)
        _ = draft.handle(.increase)
        XCTAssertEqual(draft.values.theme, .light)

        draft.selectedRow = .usagePlacement
        _ = draft.handle(.decrease)
        XCTAssertEqual(draft.values.usagePlacement, .center)
        _ = draft.handle(.decrease)
        XCTAssertEqual(draft.values.usagePlacement, .left)
        _ = draft.handle(.decrease)
        XCTAssertEqual(draft.values.usagePlacement, .left)
        _ = draft.handle(.increase)
        XCTAssertEqual(draft.values.usagePlacement, .center)
        _ = draft.handle(.increase)
        XCTAssertEqual(draft.values.usagePlacement, .right)
        _ = draft.handle(.increase)
        XCTAssertEqual(draft.values.usagePlacement, .right)
    }

    func testProviderCyclesThroughIds() {
        // `adjust` is private; cycle via the public `handle` (h/l mapping).
        var draft = SettingsDraft(values: values(), providerIds: ["anthropic", "glm", "kimi"])
        draft.selectedRow = .provider
        _ = draft.handle(.increase)   // anthropic -> glm
        XCTAssertEqual(draft.values.providerId, "glm")
        _ = draft.handle(.increase)   // glm -> kimi
        XCTAssertEqual(draft.values.providerId, "kimi")
        _ = draft.handle(.increase)   // wrap -> anthropic
        XCTAssertEqual(draft.values.providerId, "anthropic")
        _ = draft.handle(.decrease)   // anthropic -> kimi (wrap back)
        XCTAssertEqual(draft.values.providerId, "kimi")
    }

    func testEnterSavesAndEscapeCancelsFromAnySettingRow() {
        var draft = SettingsDraft(values: values())
        for row in SettingsRow.allCases {
            draft.selectedRow = row
            XCTAssertEqual(draft.handle(.activate), .save)
        }
        XCTAssertEqual(draft.handle(.cancel), .cancel)
    }

    func testCharacterMappingUsesPhysicalQwertyKeys() {
        XCTAssertEqual(settingsKey(for: "j"), .moveDown)
        XCTAssertEqual(settingsKey(for: "k"), .moveUp)
        XCTAssertEqual(settingsKey(for: "h"), .decrease)
        XCTAssertEqual(settingsKey(for: "l"), .increase)
        XCTAssertEqual(settingsKey(for: "о"), .moveDown)
        XCTAssertEqual(settingsKey(for: "л"), .moveUp)
        XCTAssertNil(settingsKey(for: "x"))
    }
}
