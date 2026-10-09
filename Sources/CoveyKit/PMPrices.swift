import Foundation

/// Одна запись прайса: $ за 1M токенов по категориям. `match` — префикс имени
/// модели (без учёта регистра); побеждает самый длинный совпавший префикс.
public struct PMPrice: Codable, Equatable, Sendable {
    public var match: String
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public init(match: String, input: Double, output: Double,
                cacheRead: Double, cacheWrite: Double) {
        self.match = match; self.input = input; self.output = output
        self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
}

public enum PMPrices {
    private struct Table: Codable { var prices: [PMPrice] }

    public static func load(bundle: Bundle) -> [PMPrice]? {
        guard let url = bundle.url(forResource: "prices", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode(Table.self, from: data) else { return nil }
        return table.prices
    }

    /// Прайс из bundle-ресурса CoveyKit (для вызова из coveyd/GUI).
    public static func loadBundled() -> [PMPrice]? { load(bundle: Bundle.module) }

    /// Стоимость в USD; nil — модель без цены (UI показывает «no price», не 0).
    public static func cost(for model: String, prices: [PMPrice],
                            input: Double, output: Double,
                            cacheRead: Double, cacheWrite: Double) -> Double? {
        let name = model.lowercased()
        var best: PMPrice? = nil
        for p in prices where name.hasPrefix(p.match.lowercased()) {
            if best == nil || p.match.count > best!.match.count { best = p }
        }
        guard let p = best else { return nil }
        let m = 1_000_000.0
        return input / m * p.input + output / m * p.output
            + cacheRead / m * p.cacheRead + cacheWrite / m * p.cacheWrite
    }
}
