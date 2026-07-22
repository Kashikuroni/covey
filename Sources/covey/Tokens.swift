import SwiftUI

/// The design system on the ayu palette (dark = ayu Mirage, light = ayu
/// Light; literals from ayu-theme/ayu-colors). Single color source for the
/// SwiftUI layer; the terminal palette lives in Theme.swift.
struct Tokens {
    // surfaces
    let bg: Color, surface: Color, surf2: Color, surf3: Color, surf4: Color
    let card: Color, cardHover: Color, termBg: Color
    // borders, three densities
    let bd: Color, bd2: Color, bd3: Color
    // text tiers, brightest to dimmest
    let t1: Color, t2: Color, t3: Color, t4: Color
    // status + diff accents
    let run: Color, wait: Color, idle: Color, ok: Color, err: Color, warn: Color
    let diffAdd: Color, diffDel: Color
    // card shadow (the primary component of --sh)
    let shadowColor: Color
    // ayu common.accent — prominent buttons, tint
    let accent: Color
    // agent brand marks (usage chip name labels)
    let claudeBrand: Color, codexBrand: Color
    // which palette this is — lets color math (label contrast) adapt to theme
    let isDark: Bool

    static let r: CGFloat = 6
    static let rSm: CGFloat = 4
    static let rLg: CGFloat = 10
    static let shadowRadius: CGFloat = 8
    static let shadowY: CGFloat = 2

    init(_ theme: Theme) {
        self = theme == .dark ? .dark : .light
    }

    private init(bg: Color, surface: Color, surf2: Color, surf3: Color, surf4: Color,
                 card: Color, cardHover: Color, termBg: Color,
                 bd: Color, bd2: Color, bd3: Color,
                 t1: Color, t2: Color, t3: Color, t4: Color,
                 run: Color, wait: Color, idle: Color, ok: Color, err: Color, warn: Color,
                 diffAdd: Color, diffDel: Color, shadowColor: Color, accent: Color,
                 claudeBrand: Color, codexBrand: Color,
                 isDark: Bool) {
        self.bg = bg; self.surface = surface; self.surf2 = surf2
        self.surf3 = surf3; self.surf4 = surf4
        self.card = card; self.cardHover = cardHover; self.termBg = termBg
        self.bd = bd; self.bd2 = bd2; self.bd3 = bd3
        self.t1 = t1; self.t2 = t2; self.t3 = t3; self.t4 = t4
        self.run = run; self.wait = wait; self.idle = idle
        self.ok = ok; self.err = err; self.warn = warn
        self.diffAdd = diffAdd; self.diffDel = diffDel
        self.shadowColor = shadowColor
        self.accent = accent
        self.claudeBrand = claudeBrand; self.codexBrand = codexBrand
        self.isDark = isDark
    }

    static let dark = Tokens(
        bg: Color(hex: 0x181C26), surface: Color(hex: 0x1F2430),
        surf2: Color(hex: 0x242936), surf3: Color(hex: 0x282E3B),
        surf4: Color(hex: 0x6E7C8F).opacity(0.4),
        card: Color(hex: 0x242936), cardHover: Color(hex: 0x282E3B),
        termBg: Color(hex: 0x242936),
        bd: Color(hex: 0x171B24),
        bd2: Color(hex: 0x6E7C8F).opacity(0.25),
        bd3: Color(hex: 0x6E7C8F).opacity(0.45),
        t1: Color(hex: 0xCCCAC2), t2: Color(hex: 0xCCCAC2).opacity(0.8),
        t3: Color(hex: 0x707A8C), t4: Color(hex: 0x707A8C).opacity(0.6),
        run: Color(hex: 0xFFA659), wait: Color(hex: 0xFFCD66),
        idle: Color(hex: 0x282E3B), ok: Color(hex: 0x87D96C),
        err: Color(hex: 0xF27983), warn: Color(hex: 0xD9BE98),
        diffAdd: Color(hex: 0x87D96C), diffDel: Color(hex: 0xF27983),
        shadowColor: Color.black.opacity(0.2),
        accent: Color(hex: 0xFFCC66),
        claudeBrand: Color(hex: 0x707A8C), codexBrand: Color(hex: 0x707A8C),
        isDark: true)

    static let light = Tokens(
        bg: Color(hex: 0xEBEEF0), surface: Color(hex: 0xF8F9FA),
        surf2: Color(hex: 0xFCFCFC), surf3: Color(hex: 0xFFFFFF),
        surf4: Color(hex: 0xADAEB1).opacity(0.5),
        card: Color(hex: 0xFCFCFC), cardHover: Color(hex: 0xFFFFFF),
        termBg: Color(hex: 0xFCFCFC),
        bd: Color(hex: 0x6B7D8F).opacity(0.12),
        bd2: Color(hex: 0x6B7D8F).opacity(0.20),
        bd3: Color(hex: 0x6B7D8F).opacity(0.32),
        t1: Color(hex: 0x5C6166), t2: Color(hex: 0x787B80),
        t3: Color(hex: 0x828E9F), t4: Color(hex: 0xABB2BD),
        run: Color(hex: 0xFA8532), wait: Color(hex: 0xEBA400),
        idle: Color(hex: 0xCED4DA), ok: Color(hex: 0x6CBF43),
        err: Color(hex: 0xFF7383), warn: Color(hex: 0xE59645),
        diffAdd: Color(hex: 0x6CBF43), diffDel: Color(hex: 0xFF7383),
        shadowColor: Color(hex: 0x6B7D8F).opacity(0.1),
        accent: Color(hex: 0xF29718),
        claudeBrand: Color(hex: 0x828E9F), codexBrand: Color(hex: 0x828E9F),
        isDark: false)
}

extension Color {
    /// Opaque sRGB color from 0xRRGGBB.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
