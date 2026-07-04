import AppKit

enum Theme: String {
    case dark, light

    init(raw: String) { self = Theme(rawValue: raw) ?? .dark }

    /// ayu editor.bg: Mirage lift / Light lift.
    var background: NSColor {
        switch self {
        case .dark:  return NSColor(hex: 0x242936)
        case .light: return NSColor(hex: 0xFCFCFC)
        }
    }
    /// ayu editor.fg.
    var foreground: NSColor {
        switch self {
        case .dark:  return NSColor(hex: 0xCCCAC2)
        case .light: return NSColor(hex: 0x5C6166)
        }
    }
    /// ayu common.accent.
    var cursor: NSColor {
        switch self {
        case .dark:  return NSColor(hex: 0xFFCC66)
        case .light: return NSColor(hex: 0xF29718)
        }
    }

    /// The 16 ANSI colors (ayu terminal sections; computed yaml values are
    /// replaced by the nearest literal of the same theme).
    var ansi: [NSColor] {
        switch self {
        case .dark: return [
            NSColor(hex: 0x0A0000), NSColor(hex: 0xF28779),   // black red
            NSColor(hex: 0xD5FF80), NSColor(hex: 0xFFCD66),   // green yellow
            NSColor(hex: 0x73D0FF), NSColor(hex: 0xDFBFFF),   // blue magenta
            NSColor(hex: 0x95E6CB), NSColor(hex: 0xCCCAC2),   // cyan white
            NSColor(hex: 0x6E7C8F), NSColor(hex: 0xF28779),   // brBlack brRed
            NSColor(hex: 0xD5FF80), NSColor(hex: 0xFFCD66),
            NSColor(hex: 0x73D0FF), NSColor(hex: 0xDFBFFF),
            NSColor(hex: 0x95E6CB), NSColor(hex: 0xFFFFFF),
        ]
        case .light: return [
            NSColor(hex: 0x5C6166), NSColor(hex: 0xF07171),
            NSColor(hex: 0x86B300), NSColor(hex: 0xEBA400),
            NSColor(hex: 0x22A4E6), NSColor(hex: 0xA37ACC),
            NSColor(hex: 0x4CBF99), NSColor(hex: 0xADAEB1),
            NSColor(hex: 0x828E9F), NSColor(hex: 0xF07171),
            NSColor(hex: 0x86B300), NSColor(hex: 0xEBA400),
            NSColor(hex: 0x22A4E6), NSColor(hex: 0xA37ACC),
            NSColor(hex: 0x4CBF99), NSColor(hex: 0xFFFFFF),
        ]
        }
    }
}

extension NSColor {
    /// Opaque sRGB color from 0xRRGGBB.
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
