import XCTest
import SwiftUI
@testable import covey

/// Реестр моделей дашборда: Covey сам создаёт запись при встрече модели в
/// метриках; пользователь задаёт цвет и цену $/1M, архивирует (история
/// остаётся с цветом/ценой) или удаляет. Хранение — один JSON в defaults.
@MainActor
final class DashboardSettingsTests: XCTestCase {
    private func fresh() -> DashboardSettings {
        let suite = UserDefaults(suiteName: "DashboardSettingsTests-\(UUID().uuidString)")!
        return DashboardSettings(defaults: suite)
    }

    func testEnsureCreatesRecordOnceAndKeepsUserFields() {
        let s = fresh()
        s.ensure("glm-4.6")
        s.setColor(hex: "#ff0000", for: "glm-4.6")
        s.setPrices(ModelPrices(input: 1.4, cachedRead: 0.26, cacheWrite: 0, output: 4.4),
                    for: "glm-4.6")
        s.ensure("glm-4.6")
        s.ensure("glm-4.5-air")
        XCTAssertEqual(s.records.count, 2, "повторная встреча не дублирует")
        XCTAssertEqual(s.records.first { $0.model == "glm-4.6" }?.colorHex, "#ff0000",
                       "поля пользователя переживают ensure")
    }

    func testArchivedKeepsPriceAndColorButFlags() {
        let s = fresh()
        s.ensure("glm-4.6")
        s.setPrices(ModelPrices(input: 1.4, cachedRead: 0.26, cacheWrite: 0, output: 4.4),
                    for: "glm-4.6")
        s.archive("glm-4.6")
        let rec = s.records.first { $0.model == "glm-4.6" }
        XCTAssertEqual(rec?.archived, true)
        XCTAssertEqual(rec?.prices?.output, 4.4, "архив хранит историю")
        s.restore("glm-4.6")
        XCTAssertEqual(s.records.first { $0.model == "glm-4.6" }?.archived, false)
    }

    func testDeleteRemovesRecord() {
        let s = fresh()
        s.ensure("glm-4.6")
        s.delete("glm-4.6")
        XCTAssertTrue(s.records.isEmpty)
    }

    func testDeletedModelIsNotResurrectedByEnsure() {
        // Удаление — осознанный выбор: автогегистрация не возвращает модель,
        // пока пользователь не сбросит tombstone.
        let s = fresh()
        s.ensure("glm-4.6")
        s.delete("glm-4.6")
        s.ensureAll(["glm-4.6", "glm-5.3"])
        XCTAssertEqual(s.records.count, 1, "удалённая не воскрешает")
        XCTAssertEqual(s.records.first?.model, "glm-5.3")
        s.resetDeleted()
        s.ensureAll(["glm-4.6"])
        XCTAssertEqual(s.records.count, 2, "после сброса модель снова регистрируется")
    }

    func testCostUsesPerModelPrice() {
        let s = fresh()
        s.ensure("glm-5.3")
        XCTAssertNil(s.cost(model: "glm-5.3", usage: GLMTokenUsage(input: 1_000_000)),
                     "без цен суммы нет")
        // Прайс z.ai: input/cached/storage/output за 1M.
        s.setPrices(ModelPrices(input: 1.4, cachedRead: 0.26, cacheWrite: 0,
                                output: 4.4), for: "glm-5.3")
        // 1M input + 2M cache read + 0.5M storage + 1M output:
        let usage = GLMTokenUsage(input: 1_000_000, output: 1_000_000,
                                  cacheCreation: 500_000, cacheRead: 2_000_000)
        XCTAssertEqual(s.cost(model: "glm-5.3", usage: usage) ?? 0,
                       1.4 + 0.52 + 0 + 4.4, accuracy: 1e-9)
        // Цена архивной модели продолжает работать (история).
        s.archive("glm-5.3")
        XCTAssertEqual(s.cost(model: "glm-5.3",
                              usage: GLMTokenUsage(input: 1_000_000)) ?? 0,
                       1.4, accuracy: 1e-9)
    }

    func testPersistenceRoundTrip() {
        let suite = UserDefaults(suiteName: "DashboardSettingsTests-\(UUID().uuidString)")!
        let s = DashboardSettings(defaults: suite)
        s.ensure("glm-4.6")
        s.setColor(hex: "#123456", for: "glm-4.6")
        s.setPrices(ModelPrices(input: 1.4, cachedRead: 0.26, cacheWrite: 0, output: 4.4),
                    for: "glm-4.6")
        s.archive("glm-4.6")
        let reloaded = DashboardSettings(defaults: suite)
        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertEqual(reloaded.records.first?.colorHex, "#123456")
        XCTAssertEqual(reloaded.records.first?.prices?.input, 1.4)
        XCTAssertEqual(reloaded.records.first?.archived, true)
    }

    func testLegacyColorHexMigrates() {
        let suite = UserDefaults(suiteName: "DashboardSettingsTests-\(UUID().uuidString)")!
        suite.set("#abcdef", forKey: "modelColor.glm-4.6")
        let s = DashboardSettings(defaults: suite)
        s.migrateLegacyColors(["glm-4.6"])
        XCTAssertEqual(s.records.first?.colorHex, "#abcdef")
        XCTAssertNil(suite.string(forKey: "modelColor.glm-4.6"), "легаси-ключ убран")
    }
}
