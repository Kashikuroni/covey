import SwiftUI

/// Both entry points use the same observable model and settings callbacks.
struct LimitsPanel: View {
    let model: AppModel

    var body: some View {
        LimitsOverlay(content: LimitsOverlayContent(
            usage: model.usage, plan: model.plan, error: model.usageError,
            codexUsage: model.codexUsage, codexPlan: model.codexPlan,
            claudeUsageEnabled: model.claudeUsageEnabled,
            codexUsageEnabled: model.codexUsageEnabled,
            onSetClaudeUsageEnabled: model.setClaudeUsageEnabled,
            onSetCodexUsageEnabled: model.setCodexUsageEnabled,
            onSetGlmUsageEnabled: model.setGlmUsageEnabled,
            glmQuota: model.glmQuota,
            glmEnabled: model.glmUsageEnabled,
            glmError: model.glmUsageError,
            glmKeyStatus: model.glmAPIKeyStatus,
            glmKeyValid: model.glmAPIKeyValid,
            onSaveGLMKey: model.setGLMAPIKey,
            selectedProvider: model.limitsSelectedProvider,
            tk: Tokens(Theme(raw: model.themeRaw)),
            menuBarLimitsEnabled: model.menuBarLimitsEnabled,
            onSetMenuBarLimitsEnabled: model.setMenuBarLimitsEnabled,
            codexError: model.codexUsageError,
            connectionError: model.usageConnectionError,
            settingsPending: model.usageSettingsPending,
            settingsAvailable: model.usageSettingsAvailable),
            onRefreshGLMKeyStatus: model.refreshGLMAPIKeyStatus)
    }
}

/// Any GLM forecast window that deserves the menu-bar «⚠»: an overflow verdict,
/// or a non-idle/non-underuse verdict whose quota runs out within the hour.
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

/// Segments for the menu-bar title. Claude/Codex keep their stable placeholder
/// slots; GLM joins only once it has data — menu-bar width is too scarce for
/// a permanent em dash of a provider that may never be configured. A non-nil
/// forecast counts as data; a risky one prefixes the value with «⚠» and keeps
/// the segment even before quota numbers arrive.
func menuBarSegments(usage: Usage?, codexUsage: CodexRateLimitsSnapshot?,
                     glmQuota: GLMQuota?, glmEnabled: Bool,
                     forecast: GLMForecast? = nil) -> [HeaderSegment] {
    var segments = headerSegments(usage: usage, usageError: nil, codexUsage: codexUsage,
                                  glmQuota: glmQuota, glmEnabled: glmEnabled)
    if glmForecastAtRisk(forecast), let index = segments.firstIndex(where: { $0.label == "GLM" }) {
        let glm = segments[index]
        segments[index] = HeaderSegment(label: glm.label,
                                        value: glm.value == "—" ? "⚠" : "⚠ " + glm.value,
                                        level: glm.level)
    }
    return segments.filter { $0.level != nil || $0.label != "GLM" || forecast != nil }
}

func menuBarLimitsTitle(usage: Usage?, codexUsage: CodexRateLimitsSnapshot?,
                        glmQuota: GLMQuota? = nil, glmEnabled: Bool = true,
                        forecast: GLMForecast? = nil) -> String {
    menuBarSegments(usage: usage, codexUsage: codexUsage, glmQuota: glmQuota, glmEnabled: glmEnabled,
                    forecast: forecast)
        .map { "\($0.label == "Codex" ? "GPT" : $0.label) \($0.value)" }
        .joined(separator: " · ")
}

struct MenuBarLimitsPanel: View {
    let model: AppModel
    @State private var contentHeight: CGFloat = 360

    var body: some View {
        ScrollView {
            NativeLimitsContent(
                rows: limitsRows(usage: model.usage, plan: model.plan, error: model.usageError,
                                 codexUsage: model.codexUsage, codexPlan: model.codexPlan,
                                 claudeEnabled: model.claudeUsageEnabled,
                                 codexEnabled: model.codexUsageEnabled,
                                 codexError: model.codexUsageError,
                                 glmQuota: model.glmQuota,
                                 glmEnabled: model.glmUsageEnabled,
                                 glmError: model.glmUsageError),
                connectionError: model.usageConnectionError,
                settingsAvailable: model.usageSettingsAvailable,
                settingsPending: model.usageSettingsPending,
                menuBarEnabled: model.menuBarLimitsEnabled,
                glmForecast: model.glmForecast,
                setEnabled: { provider, enabled in
                    switch provider {
                    case .claude: model.setClaudeUsageEnabled(enabled)
                    case .codex: model.setCodexUsageEnabled(enabled)
                    case .glm: model.setGlmUsageEnabled(enabled)
                    }
                },
                setMenuBarEnabled: model.setMenuBarLimitsEnabled)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(width: 300, height: min(contentHeight, max(200, (NSScreen.main?.visibleFrame.height ?? 700) - 80)))
        .modifier(MenuBarLimitsSurface())
        .containerBackground(.clear, for: .window)
    }
}

/// One system material for the whole panel; no nested glass cards.
struct MenuBarLimitsSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            content.background(.regularMaterial)
        }
    }
}
