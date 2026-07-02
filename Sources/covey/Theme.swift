import AppKit

enum Theme: String {
    case dark, light

    init(raw: String) { self = Theme(rawValue: raw) ?? .dark }

    var background: NSColor {
        switch self {
        case .dark:  return NSColor(red: 0x1C/255, green: 0x19/255, blue: 0x17/255, alpha: 1)
        case .light: return NSColor(red: 0xFA/255, green: 0xF7/255, blue: 0xF2/255, alpha: 1)
        }
    }
    var foreground: NSColor {
        switch self {
        case .dark:  return NSColor(red: 0xFA/255, green: 0xF7/255, blue: 0xF2/255, alpha: 1)
        case .light: return NSColor(red: 0x1C/255, green: 0x19/255, blue: 0x17/255, alpha: 1)
        }
    }
    var cursor: NSColor { .orange }
}
