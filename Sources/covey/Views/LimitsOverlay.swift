import SwiftUI

/// Maps `UsagePlacement` to a top-anchored overlay alignment — `LimitsOverlay`
/// always opens directly under wherever the compact header currently sits.
func topOverlayAlignment(_ placement: UsagePlacement) -> Alignment {
    switch placement {
    case .left: return .topLeading
    case .center: return .top
    case .right: return .topTrailing
    }
}

/// The GLM key row's caption: state word plus the action beside it
/// ("edit" once a key exists, "add" when it does not).
func glmKeyRowLabel(status: ProviderKeyStatus, valid: Bool) -> (text: String, action: String) {
    switch status {
    case .checking: return ("api key — checking…", "edit")
    case .set: return ("api key — \(valid ? "valid" : "invalid")", "edit")
    case .missing: return ("api key — invalid", "add")
    }
}

/// Прогноз окна GLM по метке чипа: «5h» → fiveHours, «7d» → weekly. Чужие
/// метки (Claude/Codex) и отсутствующий прогноз строки не дают.
func glmWindowForecast(_ label: String, forecast: GLMForecast?) -> GLMWindowForecast? {
    switch label {
    case "5h": return forecast?.fiveHours
    case "7d": return forecast?.weekly
    default: return nil
    }
}

/// Заголовок action link прогноза: открытая панель предлагает её скрыть.
func overlayForecastToggleTitle(shown: Bool) -> String {
    shown ? "Скрыть прогноз" : "Прогноз…"
}

/// Текстовое действие в языке оверлея: monospace, link-blue, без рамки —
/// замена системным кнопкам внутри стеклянной карточки. Hover подчёркивает
/// и ставит курсор-руку, нажатие гасит цвет.
struct OverlayActionLink: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color(nsColor: .linkColor))
                .underline(hovering)
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(OverlayActionLinkStyle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

/// Нажатие гасит линк — bezel нет и во взятом состоянии.
private struct OverlayActionLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

/// Detailed limits overlay (⌘L «Show Limits Detail», клик по статус-айтему):
/// полный разбор Claude/Codex/GLM в стеклянной карточке. Сама карточка живёт
/// в `LimitsOverlayContent`; враппер владеет поверхностью и второй карточкой —
/// панелью прогноза, которая по клику «Прогноз…» ложится поверх контента
/// (так же, как сам оверлей лежит поверх окна в `ContentView`).
struct LimitsOverlay: View {
    let content: LimitsOverlayContent
    var onRefreshGLMKeyStatus: () async -> Void = {}

    @State private var showingForecast = false

    private let cardWidth: CGFloat = 320

    var body: some View {
        presentable
            .task { await onRefreshGLMKeyStatus() }
            .frame(width: cardWidth)
            // Tinted with our own surface color so whatever sits behind the
            // popover (terminal text, in particular) doesn't bleed through
            // enough to fight the card's own text for legibility.
            .glassEffect(.regular.tint(content.tk.surface.opacity(0.6)), in: .rect(cornerRadius: 16))
            .shadow(radius: 12)
            .overlay(alignment: .top) {
                if showingForecast, let forecast = content.glmForecast {
                    ForecastWindowView(forecast: forecast, width: cardWidth,
                                       onClose: { showingForecast = false })
                        .glassEffect(.regular.tint(content.tk.surface.opacity(0.6)),
                                     in: .rect(cornerRadius: 16))
                        .shadow(radius: 12)
                        .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: showingForecast)
    }

    /// Контент с подключённым переключателем панели прогноза: состояние живет
    /// здесь (враппер рисует карточку), контенту уходит только замыкание.
    private var presentable: LimitsOverlayContent {
        var content = content
        content.forecastShown = showingForecast
        content.onToggleForecast = { showingForecast.toggle() }
        return content
    }
}

/// The overlay's card without the glass container — tests can render the
/// actual rows directly (glass does not paint offscreen).
struct LimitsOverlayContent: View {
    let usage: Usage?
    let plan: String?
    let error: String?
    let codexUsage: CodexRateLimitsSnapshot?
    let codexPlan: String?
    let claudeUsageEnabled: Bool
    let codexUsageEnabled: Bool
    let onSetClaudeUsageEnabled: (Bool) -> Void
    let onSetCodexUsageEnabled: (Bool) -> Void
    var onSetGlmUsageEnabled: (Bool) -> Void = { _ in }
    var glmQuota: GLMQuota? = nil
    var glmEnabled: Bool = true
    var glmError: String? = nil
    var glmForecast: GLMForecast? = nil
    var glmKeyStatus: ProviderKeyStatus = .checking
    var glmKeyValid: Bool = false
    var onSaveGLMKey: (String) async -> Bool = { _ in false }
    let selectedProvider: AppModel.LimitsProvider
    let tk: Tokens
    var menuBarLimitsEnabled = false
    var onSetMenuBarLimitsEnabled: (Bool) -> Void = { _ in }
    var codexError: String?
    var connectionError: String?
    var settingsPending = false
    var settingsAvailable = true
    /// Панель прогноза открыта (владеет `LimitsOverlay` — он её и рисует).
    var forecastShown = false
    /// Переключатель панели прогноза; nil — линка «Прогноз…» нет.
    var onToggleForecast: (() -> Void)? = nil

    @State private var showingGLMKeyField = false
    @State private var glmKeyDraft = ""
    @State private var glmKeySaving = false

    private var rows: [LimitsRowModel] {
        limitsRows(usage: usage, plan: plan, error: error,
                   codexUsage: codexUsage, codexPlan: codexPlan,
                   claudeEnabled: claudeUsageEnabled,
                   codexEnabled: codexUsageEnabled,
                   codexError: codexError,
                   glmQuota: glmQuota, glmEnabled: glmEnabled, glmError: glmError)
    }

    var body: some View {
        // Ticks every minute so reset countdowns advance even when the
        // snapshot itself is Equatable-equal.
        TimelineView(.everyMinute) { ctx in
            VStack(alignment: .leading, spacing: 0) {
                cardHeader(now: ctx.date)
                if let connectionError {
                    Text(connectionError)
                        .font(.system(size: 12))
                        .foregroundStyle(tk.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 18).padding(.bottom, 12)
                }
                ForEach(rows) { row in
                    providerSection(row: row, now: ctx.date)
                    if row.provider == .glm { glmKeyRow }
                }
                Toggle("Show in macOS menu bar", isOn: Binding(
                    get: { menuBarLimitsEnabled }, set: onSetMenuBarLimitsEnabled))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(tk.accent)
                    .font(.system(size: 12))
                    .foregroundStyle(tk.t1)
                    .padding(18)
                    .overlay(alignment: .top) { Rectangle().fill(tk.bd2).frame(height: 1) }
            }
        }
    }

    /// The one provider-specific control in the panel: GLM has no local login,
    /// so its API key is managed right here — status plus an inline editor.
    private var glmKeyRow: some View {
        let label = glmKeyRowLabel(status: glmKeyStatus, valid: glmKeyValid)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(label.text)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(glmKeyStatus == .checking ? tk.t3
                                     : (glmKeyValid ? tk.ok : tk.err))
                Spacer()
                OverlayActionLink(title: label.action) {
                    glmKeyDraft = ""
                    showingGLMKeyField.toggle()
                }
                .disabled(glmKeySaving)
            }
            if showingGLMKeyField {
                HStack(spacing: 8) {
                    SecureField("z.ai API key", text: $glmKeyDraft)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveGLMKey)
                    Button("Save", action: saveGLMKey)
                        .disabled(glmKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || glmKeySaving)
                    Button("Cancel") { showingGLMKeyField = false }
                }
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 16)
    }

    private func saveGLMKey() {
        glmKeySaving = true
        let key = glmKeyDraft
        Task {
            if await onSaveGLMKey(key) {
                showingGLMKeyField = false
                glmKeyDraft = ""
            }
            glmKeySaving = false
        }
    }

    private func cardHeader(now: Date) -> some View {
        HStack {
            Text("AI Usage Limits")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(tk.t3)
            Spacer()
            Text(headerDateTime(now))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(tk.t3)
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
    }

    private func providerSection(row: LimitsRowModel, now: Date) -> some View {
        let selected = isSelected(row.provider)
        let onSetEnabled = enabledSetter(row.provider)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(row.chip.name)
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundStyle(selected ? tk.accent : tk.t1)
                if let plan = row.chip.plan {
                    Text(plan)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tk.t2)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(tk.surf2, in: Capsule())
                }
                if row.stale { Text("*").foregroundStyle(tk.warn) }
                Spacer()
                Toggle("", isOn: Binding(get: { row.enabled }, set: onSetEnabled))
                    .disabled(settingsPending || !settingsAvailable)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(tk.accent)
                    .controlSize(.small)
                    .scaleEffect(0.8)
            }
            .opacity(row.enabled ? 1 : 0.55)
            ForEach(Array(row.chip.windows.enumerated()), id: \.offset) { entry in
                windowRow(entry.element, now: now,
                          forecast: row.provider == .glm
                              ? glmWindowForecast(entry.element.label, forecast: glmForecast)
                              : nil)
            }
            .opacity(row.enabled ? 1 : 0.55)
            if row.provider == .glm, glmForecast != nil, let onToggleForecast {
                OverlayActionLink(title: overlayForecastToggleTitle(shown: forecastShown)) {
                    onToggleForecast()
                }
            }
            if let message = row.emptyMessage {
                Text(message)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(message == "No usage data" ? tk.t3 : tk.warn)
                    .opacity(row.enabled ? 1 : 0.55)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(tk.bd2).frame(height: 1) }
    }

    private func isSelected(_ provider: UsageProvider) -> Bool {
        switch provider {
        case .claude: return selectedProvider == .claude
        case .codex: return selectedProvider == .codex
        case .glm: return selectedProvider == .glm
        }
    }

    private func enabledSetter(_ provider: UsageProvider) -> (Bool) -> Void {
        switch provider {
        case .claude: return onSetClaudeUsageEnabled
        case .codex: return onSetCodexUsageEnabled
        case .glm: return onSetGlmUsageEnabled
        }
    }

    private func windowRow(_ w: LabeledWindow, now: Date,
                           forecast: GLMWindowForecast? = nil) -> some View {
        let pct = displayUsagePercent(w.window.utilization)
        let color = pct.map { levelColor(usageLevel($0), tk: tk) } ?? tk.t3
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(w.label)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tk.t1)
                if let reset = w.window.resetUnix {
                    Text("resets in \(remainingLabel(resetUnix: reset, now: now))")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(tk.t2)
                }
                Spacer()
                Text(pct.map { "\($0)%" } ?? "—")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(tk.surf2)
                    Capsule().fill(color).frame(width: geo.size.width * CGFloat(min(100, pct ?? 0)) / 100)
                }
            }
            .frame(height: 6)
            // Прогноз под окном GLM — вторичные данные, перебор красит err-цветом.
            if let forecast, let line = ForecastText.forecastLine(forecast, label: w.label, now: now) {
                Text(line)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(forecast.verdict == .overflow
                                     ? AnyShapeStyle(tk.err) : AnyShapeStyle(tk.t2))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
