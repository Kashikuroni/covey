import SwiftUI

func nativeUsageColor(_ level: UsageLevel) -> NSColor {
    switch level {
    case .ok: return .systemGreen
    case .warn: return .systemOrange
    case .err: return .systemRed
    }
}

func menuBarLimitsAttributedTitle(usage: Usage?, codexUsage: CodexRateLimitsSnapshot?,
                                  glmQuota: GLMQuota?, glmEnabled: Bool) -> NSAttributedString {
    let title = NSMutableAttributedString()
    let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    func append(_ text: String, color: NSColor) {
        title.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
    }
    for (index, segment) in menuBarSegments(usage: usage, codexUsage: codexUsage,
                                            glmQuota: glmQuota, glmEnabled: glmEnabled).enumerated() {
        if index > 0 { append(" · ", color: .secondaryLabelColor) }
        append("\(segment.label == "Codex" ? "GPT" : segment.label) ", color: .labelColor)
        append(segment.value, color: segment.level.map(nativeUsageColor) ?? .secondaryLabelColor)
    }
    return title
}

/// Original-image rendering keeps macOS from flattening threshold colors into
/// the monochrome status-item text style. AppKit draws at the display's scale.
func menuBarLimitsImage(_ title: NSAttributedString) -> NSImage {
    let measured = title.size()
    let size = NSSize(width: ceil(measured.width), height: 22)
    let image = NSImage(size: size, flipped: false) { _ in
        title.draw(at: NSPoint(x: 0, y: floor((size.height - measured.height) / 2)))
        return true
    }
    image.isTemplate = false
    return image
}

struct MenuBarLimitsLabel: View {
    let usage: Usage?
    let codexUsage: CodexRateLimitsSnapshot?
    var glmQuota: GLMQuota? = nil
    var glmEnabled: Bool = true

    var body: some View {
        Image(nsImage: menuBarLimitsImage(menuBarLimitsAttributedTitle(usage: usage, codexUsage: codexUsage,
                                                                      glmQuota: glmQuota, glmEnabled: glmEnabled)))
            .renderingMode(.original)
            .fixedSize()
            .accessibilityLabel("Covey AI Usage Limits")
            .accessibilityValue(menuBarLimitsTitle(usage: usage, codexUsage: codexUsage,
                                                   glmQuota: glmQuota, glmEnabled: glmEnabled))
    }
}
