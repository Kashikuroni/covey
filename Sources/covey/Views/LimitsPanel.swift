import SwiftUI

/// Единственная точка входа detailed limits overlay (⌘L и клик по
/// статус-айтему ведут сюда через один observable-модель и колбэки настроек).
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
            glmForecast: model.glmForecast,
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
