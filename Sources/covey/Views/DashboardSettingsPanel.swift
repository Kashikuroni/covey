import SwiftUI
import CoveyKit

/// Шторка настроек (шестерёнка в топбаре): единое место — модели (цвет/
/// цена $/1M, архив), провайдеры и лимиты, API-ключи и вид приложения.
/// Поверх окна, 2/5 ширины; стиль айю — карточки, ayu-поля, hairline.
struct DashboardSettingsPanel: View {
    let model: AppModel
    let settings: DashboardSettings
    let tk: Tokens
    let onClose: () -> Void

    @State private var editingColor: String?
    @State private var pricingModel: String?
    @State private var priceDraft = ModelPrices(input: 0, cachedRead: 0,
                                                cacheWrite: 0, output: 0)
    @State private var priceFields: [String: String] = [:]
    @State private var confirmDelete: String?
    @State private var glmKeyDraft = ""
    @State private var glmKeyMessage: String?
    @State private var showGLMKeySheet = false
    @State private var editingProfile: ProviderProfile?
    @State private var profileKeyDraft = ""

    private var active: [ModelRecord] {
        settings.records.filter { !$0.archived }
            .sorted { ModelPalette.powerRank($0.model) < ModelPalette.powerRank($1.model) }
    }

    private var archived: [ModelRecord] {
        settings.records.filter(\.archived).sorted { $0.model < $1.model }
    }

    private var credentialProfiles: [ProviderProfile] {
        SessionProviderSelection.credentialProfiles(ProviderRegistry.load())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(tk.bd3)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    providersSection
                    apiKeysSection
                    modelsSection
                    viewSection
                }
                .padding(16)
                .padding(.bottom, 10)
            }
        }
        .background(tk.surface)
        .overlay(alignment: .leading) { Rectangle().fill(tk.bd3).frame(width: 1) }
        .foregroundStyle(tk.t1)
        .sheet(item: $editingProfile) { profile in
            profileKeySheet(profile)
        }
        .sheet(isPresented: $showGLMKeySheet) { glmKeySheet }
        .sheet(item: Binding(
            get: { pricingModel.map { PriceEditorTarget(model: $0) } },
            set: { pricingModel = $0?.model })) { target in
            priceSheet(target.model)
        }
        .onAppear {
            Task { await model.refreshGLMAPIKeyStatus() }
            Task { await model.refreshProviderKeyStatuses(credentialProfiles) }
        }
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .textCase(.uppercase)
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tk.t3)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Заголовок секции над карточкой — как в дашборде.
    private func sectionTitle(_ title: String, hint: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .textCase(.uppercase)
            Text("· \(hint)")
                .font(.caption)
                .foregroundStyle(tk.t3)
        }
    }

    private func sectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tokens.rLg).fill(tk.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.rLg).stroke(tk.bd2))
    }

    private func rowDivider(_ show: Bool) -> some View {
        Group { if show { Rectangle().fill(tk.bd2).frame(height: 1) } }
    }

    // MARK: - Провайдеры и лимиты

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Providers", hint: "limits monitoring")
            sectionCard {
                providerToggle("Claude", enabled: model.claudeUsageEnabled,
                               toggle: model.setClaudeUsageEnabled, divider: true)
                providerToggle("Codex", enabled: model.codexUsageEnabled,
                               toggle: model.setCodexUsageEnabled, divider: true)
                providerToggle("GLM", enabled: model.glmUsageEnabled,
                               toggle: model.setGlmUsageEnabled, divider: true)
                Toggle("Show limits in macOS menu bar", isOn: Binding(
                    get: { model.menuBarLimitsEnabled },
                    set: { model.setMenuBarLimitsEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11, design: .monospaced))
                    .disabled(!model.usageSettingsAvailable)
            }
        }
    }

    private func providerToggle(_ name: String, enabled: Bool,
                                toggle: @escaping (Bool) -> Void,
                                divider: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(name)
                    .font(.system(size: 11, design: .monospaced))
                Spacer()
                Toggle("\(name) monitoring", isOn: Binding(get: { enabled }, set: toggle))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(!model.usageSettingsAvailable)
            }
            .padding(.vertical, 4)
            rowDivider(divider)
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

    // MARK: - API-ключи провайдеров

    private var glmKeyListRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(keyDotColor).frame(width: 6, height: 6)
                Text("z.ai")
                    .font(.system(size: 11, design: .monospaced))
                Text(keyStatusText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(tk.t3)
                Spacer()
                Button("edit") {
                    glmKeyDraft = ""
                    glmKeyMessage = nil
                    showGLMKeySheet = true
                }
                .buttonStyle(AyuButton(tk: tk, prominent: false))
                if model.glmAPIKeyStatus == .set {
                    Button("remove") {
                        Task {
                            _ = await model.setGLMAPIKey("")
                            glmKeyMessage = nil
                        }
                    }
                    .buttonStyle(AyuButton(tk: tk, prominent: false))
                }
            }
            .padding(.vertical, 4)
            rowDivider(true)
        }
    }

    private var glmKeySheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("z.ai API key")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .textCase(.uppercase)
            SecureField("paste z.ai api key", text: $glmKeyDraft)
                .ayuField(tk)
            Text(glmKeyMessage ?? "one key for both the dashboard limits and claude-code sessions · stored locally, never leaves this Mac")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(glmKeyMessage == nil || glmKeyMessage!.hasPrefix("valid")
                                 ? tk.t3 : tk.err)
            HStack {
                Spacer()
                Button("Cancel") { showGLMKeySheet = false }
                    .buttonStyle(AyuButton(tk: tk, prominent: false))
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let key = glmKeyDraft
                    Task {
                        let ok = await model.setGLMAPIKey(key)
                        glmKeyMessage = ok ? "valid — key accepted"
                                           : "could not save — try again"
                        if ok { showGLMKeySheet = false }
                    }
                }
                .buttonStyle(AyuButton(tk: tk, prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(glmKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
        .foregroundStyle(tk.t1)
        .presentationBackground(tk.surface)
    }

    private var apiKeysSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("API keys", hint: "keychain, local only")
            sectionCard {
                // z.ai: один ключ и на лимиты дашборда, и на сессии.
                glmKeyListRow
                ForEach(Array(credentialProfiles.enumerated()), id: \.element.id) { i, profile in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(model.providerKeyStatus(profile) == .set ? tk.ok : tk.t3)
                                .frame(width: 6, height: 6)
                            Text(profile.label)
                                .font(.system(size: 11, design: .monospaced))
                            Spacer()
                            Button("edit") { profileKeyDraft = ""; editingProfile = profile }
                                .buttonStyle(AyuButton(tk: tk, prominent: false))
                            if model.providerKeyStatus(profile) == .set {
                                Button("remove") {
                                    Task { _ = await model.setProviderKey(profile, "") }
                                }
                                .buttonStyle(AyuButton(tk: tk, prominent: false))
                            }
                        }
                        .padding(.vertical, 4)
                        rowDivider(i < credentialProfiles.count - 1)
                    }
                }
            }
        }
    }

    private func profileKeySheet(_ profile: ProviderProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(profile.label) API key")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .textCase(.uppercase)
            SecureField("paste \(profile.label) api key", text: $profileKeyDraft)
                .ayuField(tk)
            Text("stored by the daemon locally, never leaves this Mac")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(tk.t3)
            HStack {
                Spacer()
                Button("Cancel") { editingProfile = nil }
                    .buttonStyle(AyuButton(tk: tk, prominent: false))
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let key = profileKeyDraft
                    editingProfile = nil
                    Task { _ = await model.setProviderKey(profile, key) }
                }
                .buttonStyle(AyuButton(tk: tk, prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(profileKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
        .foregroundStyle(tk.t1)
        .presentationBackground(tk.surface)
    }

    // MARK: - Модели

    /// Цвета имён источников в таблице Agents: Claude Code / Codex,
    /// тот же свотч-паттерн, что у моделей.
    private var sourceColorsRow: some View {
        sectionCard {
            sourceColorRow("Claude Code", source: .claudeCode)
            Divider().overlay(tk.bd2)
            sourceColorRow("Codex", source: .codex)
        }
    }

    @State private var editingSourceColor: ForecastUsageSource?

    private func sourceColorRow(_ title: String, source: ForecastUsageSource) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    editingSourceColor = editingSourceColor == source ? nil : source
                }
            } label: {
                RoundedRectangle(cornerRadius: 3)
                    .fill(settings.sourceColor(for: source))
                    .frame(width: 14, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(tk.bd2))
            }
            .buttonStyle(.plain)
            .help("Pick color")
            Text(title)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tk.t1)
            if editingSourceColor == source {
                ColorPicker("", selection: Binding(
                    get: { settings.sourceColor(for: source) },
                    set: { c in settings.setSourceColor(hex: ModelPalette.hex(c),
                                                        for: source) }),
                            supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 30)
                Button("reset") {
                    settings.resetSourceColor(for: source)
                    editingSourceColor = nil
                }
                .font(.system(size: 9, design: .monospaced))
                .buttonStyle(.plain)
                .foregroundStyle(tk.t3)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 3)
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Models", hint: "color · $ per 1M · archive")
            sourceColorsRow
            sectionCard {
                if active.isEmpty {
                    Text("No models yet — they appear as Covey meets them in metrics")
                        .font(.caption)
                        .foregroundStyle(tk.t3)
                        .padding(.vertical, 4)
                }
                ForEach(Array(active.enumerated()), id: \.element.model) { i, rec in
                    modelRow(rec, archivedRow: false,
                             divider: i < active.count - 1 || !archived.isEmpty)
                }
                if !archived.isEmpty {
                    Text("archived")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .textCase(.uppercase)
                        .foregroundStyle(tk.t3)
                        .padding(.top, 4)
                    ForEach(Array(archived.enumerated()), id: \.element.model) { i, rec in
                        modelRow(rec, archivedRow: true,
                                 divider: i < archived.count - 1 || !settings.deleted.isEmpty)
                    }
                }
                if !settings.deleted.isEmpty {
                    HStack {
                        Text("removed: \(settings.deleted.count)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(tk.t3)
                        Spacer()
                        Button("re-register removed") { settings.resetDeleted() }
                            .buttonStyle(AyuButton(tk: tk, prominent: false))
                            .font(.system(size: 9))
                            .help("Deleted models will auto-register again when met in metrics")
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private func modelRow(_ rec: ModelRecord, archivedRow: Bool, divider: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // Свотч вместо постоянного ColorPicker: тяжёлый NSView-бридж
                // в каждой строке тормозил перерисовку после archive/delete.
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        editingColor = editingColor == rec.model ? nil : rec.model
                    }
                } label: {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(settings.color(model: rec.model,
                                             within: settings.records.map(\.model)))
                        .frame(width: 14, height: 14)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(tk.bd2))
                }
                .buttonStyle(.plain)
                .help("Pick color")
                Text(rec.model)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(archivedRow ? tk.t3 : tk.t1)
                if editingColor == rec.model {
                    ColorPicker("", selection: Binding(
                        get: { settings.color(model: rec.model,
                                              within: settings.records.map(\.model)) },
                        set: { c in settings.setColor(hex: ModelPalette.hex(c), for: rec.model) }),
                                supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 30)
                }
                Spacer(minLength: 8)
                Button {
                    let p = settings.record(rec.model)?.prices
                        ?? ModelPrices(input: 0, cachedRead: 0, cacheWrite: 0, output: 0)
                    priceDraft = p
                    priceFields = ["input": str(p.input), "cached": str(p.cachedRead),
                                   "storage": str(p.cacheWrite), "output": str(p.output)]
                    pricingModel = rec.model
                } label: {
                    Text(settings.record(rec.model)?.prices != nil ? "$ set" : "$ —")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(settings.record(rec.model)?.prices != nil ? tk.t2 : tk.t3)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(tk.surf2))
                        .overlay(Capsule().stroke(tk.bd2))
                }
                .buttonStyle(.plain)
                .help("Pricing: input / cached read / cache storage / output, $ per 1M")
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        archivedRow ? settings.restore(rec.model) : settings.archive(rec.model)
                    }
                } label: {
                    Image(systemName: archivedRow ? "arrow.uturn.backward" : "archivebox")
                        .font(.system(size: 11))
                        .foregroundStyle(tk.t3)
                }
                .buttonStyle(.plain)
                .help(archivedRow ? "Restore to active"
                                  : "Archive — keep color and price for history")
                // Удаление с подтверждением на месте: первый клик armed
                // («sure?»), второй — удаляет; снятие через 2.5 с.
                if confirmDelete == rec.model {
                    Button("sure?") {
                        confirmDelete = nil
                        withAnimation(.easeInOut(duration: 0.15)) {
                            settings.delete(rec.model)
                        }
                    }
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tk.err)
                    .buttonStyle(.plain)
                    .task {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        if confirmDelete == rec.model { confirmDelete = nil }
                    }
                } else {
                    Button {
                        confirmDelete = rec.model
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(tk.t3)
                    }
                    .buttonStyle(.plain)
                    .help("Delete the record — the model returns to the default palette")
                }
            }
            .padding(.vertical, 3)
            rowDivider(divider)
        }
    }

    private func str(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    private func num(_ key: String) -> Double {
        Double((priceFields[key] ?? "").replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    /// Целевой объект шита прайса (Identifiable по имени модели).
    private struct PriceEditorTarget: Identifiable {
        var model: String
        var id: String { model }
    }

    /// Пресет прайсов z.ai (октябрь 2026, storage — limited-time free).
    private static let zaiPricing: [String: ModelPrices] = [
        "glm-5.3": ModelPrices(input: 1.4, cachedRead: 0.26, cacheWrite: 0, output: 4.4),
        "glm-5.2": ModelPrices(input: 1.4, cachedRead: 0.26, cacheWrite: 0, output: 4.4),
        "glm-5.3-flash": ModelPrices(input: 0.15, cachedRead: 0.03, cacheWrite: 0, output: 0.5),
        "glm-5.3-flashx": ModelPrices(input: 0.37, cachedRead: 0.075, cacheWrite: 0, output: 1.25),
    ]

    private func priceSheet(_ model: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
            ForEach([("input", "Input"), ("cached", "Cached input"),
                     ("storage", "Cache storage"), ("output", "Output")], id: \.0) { key, label in
                HStack {
                    Text(label)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 110, alignment: .leading)
                    TextField("0", text: Binding(
                        get: { priceFields[key] ?? "" },
                        set: { priceFields[key] = $0 }))
                        .ayuField(tk)
                        .frame(width: 90)
                    Text("$ / 1M")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(tk.t3)
                }
            }
            if Self.zaiPricing[model.lowercased()] != nil {
                Button("Apply z.ai list price") {
                    let p = Self.zaiPricing[model.lowercased()]!
                    priceFields = ["input": str(p.input), "cached": str(p.cachedRead),
                                   "storage": str(p.cacheWrite), "output": str(p.output)]
                }
                .buttonStyle(AyuButton(tk: tk, prominent: false))
                .font(.system(size: 10))
            }
            HStack {
                Button("Clear") {
                    settings.setPrices(nil, for: model)
                    pricingModel = nil
                }
                .buttonStyle(AyuButton(tk: tk, prominent: false))
                Spacer()
                Button("Cancel") { pricingModel = nil }
                    .buttonStyle(AyuButton(tk: tk, prominent: false))
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    settings.setPrices(ModelPrices(input: num("input"),
                                                   cachedRead: num("cached"),
                                                   cacheWrite: num("storage"),
                                                   output: num("output")),
                                       for: model)
                    pricingModel = nil
                }
                .buttonStyle(AyuButton(tk: tk, prominent: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
        .foregroundStyle(tk.t1)
        .presentationBackground(tk.surface)
    }

    // MARK: - Вид

    private var viewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("View", hint: "panels · theme")
            sectionCard {
                performToggle("Sessions panel", command: .toggleSessionsPanel,
                              isOn: model.showSessions, divider: true)
                performToggle("Top bar", command: .toggleTopBar,
                              isOn: model.showHeader, divider: true)
                performToggle("Status bar", command: .toggleStatusBar,
                              isOn: model.showFooter, divider: true)
                HStack {
                    Text("Theme")
                        .font(.system(size: 11, design: .monospaced))
                    Spacer()
                    themeChip("Dark", value: "dark")
                    themeChip("Light", value: "light")
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func themeChip(_ title: String, value: String) -> some View {
        let on = model.themeRaw == value
        return Button {
            model.setTheme(value)
        } label: {
            Text(title)
                .font(.system(size: 9, weight: on ? .semibold : .regular, design: .monospaced))
                .textCase(.uppercase)
                .foregroundStyle(on ? tk.t1 : tk.t3)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(on ? tk.surf3 : Color.clear))
                .overlay(Capsule().stroke(tk.bd2))
        }
        .buttonStyle(.plain)
    }

    private func performToggle(_ name: String, command: AppCommand, isOn: Bool,
                               divider: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(name)
                    .font(.system(size: 11, design: .monospaced))
                Spacer()
                Toggle(name, isOn: Binding(
                    get: { isOn },
                    set: { flip in
                        if flip != isOn { model.perform(command) }
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            .padding(.vertical, 4)
            rowDivider(divider)
        }
    }
}
