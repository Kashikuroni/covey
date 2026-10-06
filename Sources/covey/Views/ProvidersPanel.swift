import SwiftUI
import CoveyKit

/// Модалка провайдеров (⌘L / клик по часам в топ-баре): мониторинг Claude,
/// Codex и GLM, ключ z.ai, тарифный режим. В режиме Forecast её заменил
/// инлайн-стрип; здесь — единственное место настройки мониторинга.
struct ProvidersPanel: View {
    let model: AppModel

    @State private var showKeySheet = false
    @State private var keyDraft = ""
    @State private var keyMessage: String?

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 0) {
                claudeRow(now: context.date)
                Divider().overlay(tk.bd2)
                codexRow(now: context.date)
                Divider().overlay(tk.bd2)
                glmRow(now: context.date)
            }
            .padding(14)
            .frame(width: 560)
            .font(.system(size: 12))
            .foregroundStyle(tk.t1)
        }
        .background(tk.surface)
        .sheet(isPresented: $showKeySheet, onDismiss: { keyMessage = nil }) {
            keySheet
        }
    }

    // MARK: - Rows

    private func claudeRow(now: Date) -> some View {
        providerRow(name: "Claude", plan: model.plan, enabled: model.claudeUsageEnabled,
                    stale: model.usage != nil && model.usageError != nil,
                    error: model.usageError ?? model.usageConnectionError,
                    toggle: Binding(
                        get: { model.claudeUsageEnabled },
                        set: { model.setClaudeUsageEnabled($0) })) {
            if let usage = model.usage {
                VStack(alignment: .leading, spacing: 2) {
                    windowChip("5h", usage.fiveHour, now: now)
                    windowChip("7d", usage.sevenDay, now: now)
                    windowChip("7d sonnet", usage.sevenDaySonnet, now: now)
                }
            } else {
                Text("no usage data").foregroundStyle(tk.t3)
            }
        }
    }

    private func codexRow(now: Date) -> some View {
        providerRow(name: "Codex", plan: model.codexPlan, enabled: model.codexUsageEnabled,
                    stale: model.codexUsage != nil && model.codexUsageError != nil,
                    error: model.codexUsageError,
                    toggle: Binding(
                        get: { model.codexUsageEnabled },
                        set: { model.setCodexUsageEnabled($0) })) {
            if let windows = model.codexUsage?.windows, !windows.isEmpty {
                // gpt-reserve — вспомогательный резерв, в панели не нужен.
                let visible = windows.filter {
                    !$0.label.localizedCaseInsensitiveContains("gpt-reserve")
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(visible, id: \.label) { labeled in
                        windowChip(labeled.label, labeled.window, now: now)
                    }
                }
            } else {
                Text("no data").foregroundStyle(tk.t3)
            }
        }
    }

    private func glmRow(now: Date) -> some View {
        providerRow(name: "GLM", plan: model.glmQuota?.plan.capitalized, enabled: model.glmUsageEnabled,
                    stale: model.glmQuota != nil && model.glmUsageError != nil,
                    error: model.glmUsageError,
                    keyControls: keyControls,
                    underName: {
                        if let forecast = model.glmForecast {
                            regimeLines(forecast, now: now)
                        }
                    },
                    toggle: Binding(
                        get: { model.glmUsageEnabled },
                        set: { model.setGlmUsageEnabled($0) })) {
            if let limits = model.glmQuota?.limits {
                VStack(alignment: .leading, spacing: 2) {
                    glmChip("5h", window: limits.fiveHours, now: now)
                    glmChip("7d", window: limits.weekly, now: now)
                }
            } else {
                Text("no usage data — connect the API key").foregroundStyle(tk.t3)
            }
        }
    }

    /// One panel line: name · plan · (stale *) [+ под именем] — windows —
    /// key (GLM) — toggle.
    private func providerRow<Windows: View>(name: String, plan: String?, enabled: Bool,
                                            stale: Bool, error: String?,
                                            keyControls: some View = EmptyView(),
                                            @ViewBuilder underName: () -> some View = { EmptyView() },
                                            toggle: Binding<Bool>,
                                            @ViewBuilder windows: () -> Windows) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(name)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                        planCapsule(plan)
                        if stale {
                            Text("*").font(.system(size: 12, weight: .bold))
                                .foregroundStyle(tk.warn)
                                .help("Last poll failed — showing the previous snapshot")
                        }
                    }
                    underName()
                }
                .frame(minWidth: 118, alignment: .leading)
                HStack(spacing: 16) {
                    if enabled { windows() }
                    else {
                        Text("monitoring off — snapshots are not loaded").foregroundStyle(tk.t3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                keyControls
                Toggle("\(name) monitoring", isOn: toggle)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(!model.usageSettingsAvailable)
            }
            .padding(.vertical, 5)
            .opacity(enabled ? 1 : 0.55)
            if let error, enabled {
                Text(error)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tk.err)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }
        }
    }

    // MARK: - GLM key

    @ViewBuilder
    private var keyControls: some View {
        HStack(spacing: 6) {
            switch model.glmAPIKeyStatus {
            case .missing:
                Button("add key") { openKeySheet() }
                    .buttonStyle(.link)
                    .font(.system(size: 11, design: .monospaced))
            case .checking:
                Text("checking…").font(.system(size: 11, design: .monospaced)).foregroundStyle(tk.warn)
            case .set:
                Button("key") { openKeySheet() }
                    .buttonStyle(.link)
                    .font(.system(size: 11, design: .monospaced))
            }
            Circle()
                .fill(keyDotColor)
                .frame(width: 6, height: 6)
                .help("API key — \(keyStatusText)")
        }
    }

    private var keyStatusText: String {
        switch model.glmAPIKeyStatus {
        case .checking: return "checking…"
        case .missing: return "not set"
        case .set: return model.glmAPIKeyValid ? "valid" : "invalid"
        }
    }

    private var keyDotColor: Color {
        switch model.glmAPIKeyStatus {
        case .checking: return tk.warn
        case .missing: return tk.t3
        case .set: return model.glmAPIKeyValid ? tk.ok : tk.err
        }
    }

    // MARK: - Chips

    /// Claude/Codex chip: `5h 42% ▬ 3h 05m`.
    @ViewBuilder
    private func windowChip(_ label: String, _ usage: UsageWindow?, now: Date) -> some View {
        if let usage {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(tk.t3)
                Text(ForecastEN.pct(usage.utilization))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(levelColor(usage.utilization))
                miniCapsule(usage.utilization)
                if let reset = usage.resetUnix.flatMap(secsToDate) {
                    Text("resets \(ForecastEN.duration(from: now, to: reset))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(tk.t3)
                }
            }
        }
    }

    /// GLM chip: `5h 18% ▬ resets 2h 52m`.
    @ViewBuilder
    private func glmChip(_ label: String, window: GLMLimitWindow?, now: Date) -> some View {
        if let window {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(tk.t3)
                Text(ForecastEN.pct(window.usedPercent))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(levelColor(window.usedPercent))
                miniCapsule(window.usedPercent)
                if let reset = msToDate(window.resetAt) {
                    Text("resets \(ForecastEN.duration(from: now, to: reset))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(tk.t3)
                }
            }
        }
    }

    /// Тарифный режим GLM под именем: название (пик — жёлтым, как процент
    /// >50%), под ним мелко время следующей смены. Калибровка — в тултипе.
    private func regimeLines(_ forecast: GLMForecast, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(forecast.peakNow ? "Peak" : "Off-peak")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(forecast.peakNow ? tk.warn : tk.t3)
            if let flip = forecast.nextFlipAt.flatMap(msToDate) {
                Text("\(forecast.peakNow ? "off-peak" : "peak") at \(ForecastText.time.string(from: flip)) (\(ForecastEN.duration(from: now, to: flip)))")
                    .font(.system(size: 9))
                    .foregroundStyle(tk.t3)
            }
        }
        .help(calibrationSummary(forecast, now: now))
    }

    private func calibrationSummary(_ forecast: GLMForecast, now: Date) -> String {
        func line(_ label: String, factor: Double?, at: Int64?) -> String {
            let value = ForecastEN.factor(factor, calibratedAt: at.flatMap(msToDate), now: now)
            return "\(label): \(value) cr/token"
        }
        return [line("peak", factor: forecast.factorPeak, at: forecast.factorPeakAt),
                line("off-peak", factor: forecast.factorOffPeak, at: forecast.factorOffPeakAt)]
            .joined(separator: "\n")
    }

    // MARK: - Small chrome

    private func planCapsule(_ plan: String?) -> some View {
        Text(plan ?? "—")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .textCase(.uppercase)
            .foregroundStyle(tk.t2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tk.surf3))
            .overlay(Capsule().stroke(tk.bd2))
    }

    private func miniCapsule(_ percent: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(tk.surf3)
            Capsule()
                .fill(levelColor(percent))
                .frame(width: 34 * min(max(percent, 0), 100) / 100)
        }
        .frame(width: 34, height: 4)
    }

    private func levelColor(_ percent: Double) -> Color {
        if percent < 50 { return tk.ok }
        if percent < 80 { return tk.warn }
        return tk.err
    }

    // MARK: - API key sheet

    private func openKeySheet() {
        keyDraft = ""
        keyMessage = nil
        showKeySheet = true
        Task { await model.refreshGLMAPIKeyStatus() }
    }

    private var keySheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("GLM API key").font(.headline)
                Spacer()
                Button {
                    showKeySheet = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(tk.t3)
            }
            Text("z.ai API key")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .textCase(.uppercase)
                .foregroundStyle(tk.t3)
            SecureField("paste your z.ai API key", text: $keyDraft)
                .textFieldStyle(.roundedBorder)
            Text(keyMessage ?? "api key — \(keyStatusText) · stored by the daemon locally, never leaves this Mac")
                .font(.caption.monospacedDigit())
                .foregroundStyle(keyMessage == nil ? tk.t3 : (keyMessage!.hasPrefix("valid") ? tk.ok : tk.err))
            HStack {
                Spacer()
                Button("Cancel") { showKeySheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        let ok = await model.setGLMAPIKey(keyDraft)
                        keyMessage = ok
                            ? "valid — key accepted, waiting for the first snapshot"
                            : "could not save the key — try again"
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
        .foregroundStyle(tk.t1)
        .presentationBackground(tk.surface)
    }

    // MARK: - Units

    private func msToDate(_ ms: Int64) -> Date? {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    private func secsToDate(_ secs: Int64) -> Date? {
        Date(timeIntervalSince1970: Double(secs))
    }
}
