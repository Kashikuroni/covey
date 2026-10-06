import SwiftUI

/// Палитра столбчатого графика «токены по моделям» (§7d): провайдер задаёт
/// базовый тон — Claude оранжевый, GPT бирюзовый, GLM розовый; модели одного
/// провайдера различаются оттенком: мощнее — насыщеннее, слабее — светлее.
/// Пользовательский цвет из настроек графика сильнее дефолта.
enum ModelPalette {
    enum Provider: Equatable { case claude, gpt, glm, other }

    /// Класс мощности модели для долей «flagship vs облегчённые» (этап 1.4).
    enum Tier: Equatable { case top, mid, light, other }

    static func provider(of model: String) -> Provider {
        let m = model.lowercased()
        if m.contains("glm") || m.contains("zai") { return .glm }
        if m.hasPrefix("claude") || m.contains("anthropic") { return .claude }
        if m.hasPrefix("gpt") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4")
            || m.contains("codex") || m.contains("chatgpt") { return .gpt }
        return .other
    }

    /// top/mid/light по положению в тире провайдера; облегчённые суффиксы
    /// (air/mini/flash/haiku) — всегда light независимо от версии.
    static func tier(of model: String) -> Tier {
        let m = model.lowercased()
        if m.contains("air") || m.contains("mini") || m.contains("flash") || m.contains("haiku") {
            return .light
        }
        let rank = powerRank(m)
        switch provider(of: m) {
        case .claude:
            return rank == 0 ? .top : rank == 1 ? .mid : .other
        case .glm:
            return rank == 3 ? .top : rank == 4 ? .mid : .other
        case .gpt:
            return rank == 6 ? .top : rank == 7 || rank == 8 ? .mid : .other
        case .other:
            return .other
        }
    }

    /// Ранг «мощности»: меньше — мощнее. Сравнивать имеет смысл внутри одного
    /// провайдера; список тиров — известные семейства по убыванию силы.
    static func powerRank(_ model: String) -> Int {
        let m = model.lowercased()
        let tiers: [[String]] = [
            ["opus"], ["sonnet"], ["haiku"],
            ["glm-4.6"], ["glm-4.5"], ["glm-4"],
            ["gpt-5"], ["gpt-4.5"], ["gpt-4o"], ["o4", "o3", "o1"],
        ]
        return tiers.firstIndex { tier in tier.contains { m.contains($0) } } ?? tiers.count
    }

    /// Цвет модели: базовый тон провайдера, светлее на каждый шаг вниз по
    /// мощности среди моделей того же провайдера в выборке.
    static func defaultColor(model: String, within siblings: [String]) -> Color {
        let p = provider(of: model)
        let base: Color
        switch p {
        case .claude: base = Color(red: 0.95, green: 0.45, blue: 0.10)     // оранжевый
        case .gpt: base = Color(red: 0.07, green: 0.68, blue: 0.62)        // бирюзовый
        case .glm: base = Color(red: 0.93, green: 0.27, blue: 0.67)        // розовый
        case .other: base = Color(red: 0.55, green: 0.55, blue: 0.58)
        }
        let same = siblings.filter { provider(of: $0) == p }
            .sorted { powerRank($0) < powerRank($1) }
        guard let i = same.firstIndex(of: model), same.count > 1 else { return base }
        let mix = min(0.55, 0.18 * Double(i))
        return blend(base, toward: .white, fraction: mix)
    }

    /// Итоговый цвет с пользовательскими переопределениями.
    static func color(model: String, within siblings: [String],
                      overrides: [String: Color]) -> Color {
        overrides[model] ?? defaultColor(model: model, within: siblings)
    }

    private static func blend(_ a: Color, toward b: Color, fraction: Double) -> Color {
        let x = NSColor(a).usingColorSpace(.deviceRGB) ?? .gray
        let y = NSColor(b).usingColorSpace(.deviceRGB) ?? .white
        let t = CGFloat(fraction)
        return Color(red: Double(x.redComponent + (y.redComponent - x.redComponent) * t),
                     green: Double(x.greenComponent + (y.greenComponent - x.greenComponent) * t),
                     blue: Double(x.blueComponent + (y.blueComponent - x.blueComponent) * t))
    }

    // MARK: - Хранение настроек (UserDefaults hex)

    static func hex(_ color: Color) -> String {
        let c = NSColor(color).usingColorSpace(.deviceRGB) ?? .black
        return String(format: "#%02x%02x%02x",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }

    static func color(fromHex hex: String) -> Color? {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}
