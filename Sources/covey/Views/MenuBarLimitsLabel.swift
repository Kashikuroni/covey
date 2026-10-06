import SwiftUI

func nativeUsageColor(_ level: UsageLevel) -> NSColor {
    switch level {
    case .ok: return .systemGreen
    case .warn: return .systemOrange
    case .err: return .systemRed
    }
}

/// Both GLM forecast windows that deserve the menu-bar «⚠»: an overflow
/// verdict, or a non-idle/non-underuse verdict whose quota runs out within
/// the hour.
func glmForecastAtRisk(_ forecast: GLMForecast?) -> Bool {
    guard let forecast else { return false }
    for window in [forecast.fiveHours, forecast.weekly] {
        guard let window else { continue }
        if window.verdict == .overflow { return true }
        if let eta = window.exhaustionAt,
           eta - Int64(Date().timeIntervalSince1970 * 1000) < 60 * 60_000,
           window.verdict != .idle, window.verdict != .underuse { return true }
    }
    return false
}

/// Segments for the status-item title. Disabled providers free their slots;
/// GLM joins only once it has data — status-item width is too scarce for a
/// permanent em dash of a provider that may never be configured. A non-nil
/// forecast counts as data; a risky one prefixes the value with «⚠» and
/// keeps the segment even before quota numbers arrive.
func menuBarSegments(usage: Usage?, codexUsage: CodexRateLimitsSnapshot?,
                     glmQuota: GLMQuota?, glmEnabled: Bool,
                     forecast: GLMForecast? = nil,
                     claudeEnabled: Bool = true, codexEnabled: Bool = true,
                     now: Date = Date()) -> [HeaderSegment] {
    var segments = headerSegments(usage: usage, usageError: nil, codexUsage: codexUsage,
                                  glmQuota: glmQuota, glmEnabled: glmEnabled,
                                  claudeEnabled: claudeEnabled, codexEnabled: codexEnabled,
                                  now: now)
    if glmForecastAtRisk(forecast), let index = segments.firstIndex(where: { $0.label == "GLM" }) {
        let glm = segments[index]
        segments[index] = HeaderSegment(label: glm.label, windowTag: glm.windowTag,
                                        value: glm.value == "—" ? "⚠" : "⚠ " + glm.value,
                                        level: glm.level)
    }
    return segments.filter { $0.level != nil || $0.label != "GLM" || forecast != nil }
}

func menuBarLimitsTitle(usage: Usage?, codexUsage: CodexRateLimitsSnapshot?,
                        glmQuota: GLMQuota? = nil, glmEnabled: Bool = true,
                        forecast: GLMForecast? = nil,
                        claudeEnabled: Bool = true, codexEnabled: Bool = true,
                        now: Date = Date()) -> String {
    menuBarSegments(usage: usage, codexUsage: codexUsage, glmQuota: glmQuota, glmEnabled: glmEnabled,
                    forecast: forecast, claudeEnabled: claudeEnabled, codexEnabled: codexEnabled,
                    now: now)
        .map { seg in
            let label = seg.label == "Codex" ? "GPT" : seg.label
            let tag = seg.windowTag.map { "\($0) " } ?? ""
            return "\(label) \(tag)\(seg.value)"
        }
        .joined(separator: " · ")
}

func menuBarLimitsAttributedTitle(usage: Usage?, codexUsage: CodexRateLimitsSnapshot?,
                                  glmQuota: GLMQuota?, glmEnabled: Bool,
                                  forecast: GLMForecast? = nil,
                                  claudeEnabled: Bool = true, codexEnabled: Bool = true,
                                  now: Date = Date()) -> NSAttributedString {
    let title = NSMutableAttributedString()
    let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    func append(_ text: String, color: NSColor) {
        title.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
    }
    for (index, segment) in menuBarSegments(usage: usage, codexUsage: codexUsage,
                                            glmQuota: glmQuota, glmEnabled: glmEnabled,
                                            forecast: forecast,
                                            claudeEnabled: claudeEnabled,
                                            codexEnabled: codexEnabled,
                                            now: now).enumerated() {
        if index > 0 { append(" · ", color: .secondaryLabelColor) }
        append("\(segment.label == "Codex" ? "GPT" : segment.label) ", color: .labelColor)
        if let tag = segment.windowTag { append("\(tag) ", color: .secondaryLabelColor) }
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
