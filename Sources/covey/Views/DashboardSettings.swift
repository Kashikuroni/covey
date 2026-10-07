import SwiftUI
import Foundation
import CoveyKit

/// Прайс модели в формате провайдеров: $ за 1M токенов по типам биллинга
/// (input / чтение кэша / запись кэша / output). Например, z.ai:
/// GLM-5.3 — in $1.4, cached $0.26, storage free, out $4.4.
struct ModelPrices: Codable, Equatable {
    var input: Double
    var cachedRead: Double
    var cacheWrite: Double
    var output: Double
}

/// Одна модель в реестре дашборда: цвет и прайс задаются пользователем,
/// архив сохраняет историю (цвет/цена продолжают работать), удаление
/// стирает запись — модель вернётся к палитре по умолчанию при новой встрече.
struct ModelRecord: Codable, Equatable, Identifiable {
    var id: String { model }
    var model: String
    var colorHex: String?
    var prices: ModelPrices?
    var archived: Bool = false
}

/// Реестр моделей + persistence (один JSON в UserDefaults). Covey создаёт
/// запись сам, когда модель встречается в метриках (ensure); пользователь
/// правит цвет/цену, архивирует или удаляет в панели настроек дашборда.
/// Удалённые модели помнятся tombstone'ом — автогегистрация их не
/// воскрешает, пока пользователь не сбросит (`resetDeleted`).
@MainActor
final class DashboardSettings: ObservableObject {
    @Published private(set) var records: [ModelRecord] = []
    @Published private(set) var deleted: [String] = []
    let defaults: UserDefaults
    private static let key = "dashboard.modelRecords"
    private static let deletedKey = "dashboard.deletedModels"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([ModelRecord].self, from: data) {
            records = decoded
        }
        if let data = defaults.data(forKey: Self.deletedKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            deleted = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.key)
        }
        if let data = try? JSONEncoder().encode(deleted) {
            defaults.set(data, forKey: Self.deletedKey)
        }
    }

    func record(_ model: String) -> ModelRecord? {
        records.first { $0.model == model }
    }

    /// Встреча модели в метриках: создаёт запись, существующие не трогает,
    /// удалённые пользователем не воскрешает.
    func ensure(_ model: String) {
        guard !model.isEmpty, record(model) == nil,
              !deleted.contains(model) else { return }
        records.append(ModelRecord(model: model))
        save()
    }

    func ensureAll(_ models: [String]) {
        var changed = false
        for m in models where !m.isEmpty && record(m) == nil && !deleted.contains(m) {
            records.append(ModelRecord(model: m))
            changed = true
        }
        if changed { save() }
    }

    private func mutate(_ model: String, _ change: (inout ModelRecord) -> Void) {
        guard let i = records.firstIndex(where: { $0.model == model }) else { return }
        change(&records[i])
        save()
    }

    func setColor(hex: String?, for model: String) {
        mutate(model) { $0.colorHex = hex }
    }

    func setPrices(_ prices: ModelPrices?, for model: String) {
        mutate(model) { $0.prices = prices }
    }

    func archive(_ model: String) {
        mutate(model) { $0.archived = true }
    }

    func restore(_ model: String) {
        mutate(model) { $0.archived = false }
    }

    func delete(_ model: String) {
        records.removeAll { $0.model == model }
        if !deleted.contains(model) { deleted.append(model) }
        save()
    }

    /// Сброс tombstone'ов: удалённые модели снова авторегистрируются при
    /// встрече в метриках.
    func resetDeleted() {
        deleted.removeAll()
        save()
    }

    /// $ за использование по компонентам биллинга и прайсу модели
    /// (in/cached/storage/out за 1M); работает и для архивной (история).
    func cost(model: String, usage: GLMTokenUsage) -> Double? {
        guard let p = record(model)?.prices else { return nil }
        return (usage.input / 1_000_000 * p.input
            + usage.cacheRead / 1_000_000 * p.cachedRead
            + usage.cacheCreation / 1_000_000 * p.cacheWrite
            + usage.output / 1_000_000 * p.output)
    }

    /// Цвет модели: пользовательский из записи, иначе дефолт палитры
    /// (оттенок по провайдеру/мощности среди известных моделей).
    func color(model: String, within siblings: [String]) -> Color {
        if let hex = record(model)?.colorHex, let c = ModelPalette.color(fromHex: hex) {
            return c
        }
        return ModelPalette.defaultColor(model: model, within: siblings)
    }

    // MARK: - Цвета имён источников (таблица Agents)

    /// Дефолтные цвета имён: Claude Code — оранжевый, Codex — бирюзовый
    /// (те же базовые тона, что в палитре моделей); оба читаемы на тёмном.
    static func defaultSourceColorHex(_ source: ForecastUsageSource) -> String {
        source == .codex ? "#12AD9E" : "#F2731A"
    }

    func sourceColorHex(for source: ForecastUsageSource) -> String {
        defaults.string(forKey: "dashboard.sourceColor.\(source.rawValue)")
            ?? Self.defaultSourceColorHex(source)
    }

    func setSourceColor(hex: String, for source: ForecastUsageSource) {
        defaults.set(hex, forKey: "dashboard.sourceColor.\(source.rawValue)")
    }

    func resetSourceColor(for source: ForecastUsageSource) {
        defaults.removeObject(forKey: "dashboard.sourceColor.\(source.rawValue)")
    }

    func sourceColor(for source: ForecastUsageSource) -> Color {
        ModelPalette.color(fromHex: sourceColorHex(for: source))
            ?? ModelPalette.color(fromHex: Self.defaultSourceColorHex(source))
            ?? .gray
    }

    /// Разовая миграция цветов старого формата `modelColor.<model>`.
    func migrateLegacyColors(_ known: [String]) {
        var changed = false
        for model in known {
            let legacyKey = "modelColor.\(model)"
            if let hex = defaults.string(forKey: legacyKey) {
                ensure(model)
                mutate(model) { $0.colorHex = hex }
                defaults.removeObject(forKey: legacyKey)
                changed = true
            }
        }
        if changed { save() }
    }
}
