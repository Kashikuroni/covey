import SwiftUI
import CoveyKit

struct SettingsSheet: View {
    let model: AppModel
    @State private var draft: SettingsDraft
    @State private var showingKeySheet = false
    @FocusState private var keyboardFocused: Bool

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    private var profiles: [ProviderProfile] { ProviderRegistry.load() }
    private var activeProfile: ProviderProfile {
        profiles.first { $0.id == draft.values.providerId } ?? .anthropic
    }
    private var providerKeyLabel: String? {
        guard activeProfile.needsKey else { return nil }
        return model.providerKeyIsSet(activeProfile)
            ? "\(activeProfile.label) API key set ✓"
            : "Set \(activeProfile.label) API key…"
    }

    @ViewBuilder
    private var providerKeyRow: some View {
        if let label = providerKeyLabel {
            Button {
                draft.selectedRow = .providerKey
                showingKeySheet = true
                keyboardFocused = true
            } label: {
                HStack(spacing: 8) {
                    Text(label)
                        .font(.callout)
                        .foregroundStyle(draft.selectedRow == .providerKey ? tk.accent : tk.t1)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .settingsRow()
        }
    }

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: SettingsDraft(
            values: model.settingsValues,
            providerIds: ProviderRegistry.load().map { $0.id }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.headline)
            section("Appearance") {
                choiceRow(.theme, label: "Theme",
                          choices: [("Dark", Theme.dark), ("Light", Theme.light)],
                          selection: $draft.values.theme)
                checkboxRow(.vimMode, label: "Vim mode", value: $draft.values.vimMode)
            }
            section("Claude Code") {
                choiceRow(.provider, label: "Provider",
                          choices: profiles.map { ($0.label, $0.id) },
                          selection: $draft.values.providerId)
                providerKeyRow
            }
            section("Layout") {
                checkboxRow(.showSessions, label: "Show sessions",
                            value: $draft.values.showSessions)
                checkboxRow(.showHeader, label: "Show top bar",
                            value: $draft.values.showHeader)
                checkboxRow(.showFooter, label: "Show status bar",
                            value: $draft.values.showFooter)
            }
            section("Usage") {
                choiceRow(.usagePlacement, label: "Usage position",
                          choices: [("Left", UsagePlacement.left),
                                    ("Center", UsagePlacement.center),
                                    ("Right", UsagePlacement.right)],
                          selection: $draft.values.usagePlacement)
                checkboxRow(.claudeUsage, label: "Claude usage limits",
                            value: $draft.values.claudeUsageEnabled)
                checkboxRow(.codexUsage, label: "Codex usage limits",
                            value: $draft.values.codexUsageEnabled)
                checkboxRow(.glmUsage, label: "GLM usage limits",
                            value: $draft.values.glmUsageEnabled)
            }
            actionRow
        }
        .padding(20)
        .frame(width: 480)
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
        .onAppear { keyboardFocused = true }
        .onKeyPress(phases: .down) { press in handle(press) }
        .sheet(isPresented: $showingKeySheet) {
            ProviderKeySheet(profile: activeProfile, model: model,
                             isPresented: $showingKeySheet)
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(tk.t1)
            content()
        }
    }

    private func checkboxRow(
        _ row: SettingsRow,
        label: String,
        value: Binding<Bool>
    ) -> some View {
        Button {
            draft.selectedRow = row
            value.wrappedValue.toggle()
            keyboardFocused = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: value.wrappedValue ? "checkmark.square.fill" : "square")
                    .foregroundStyle(value.wrappedValue ? tk.accent : tk.t3)
                Text(label)
                    .font(.callout)
                    .foregroundStyle(draft.selectedRow == row ? tk.accent : tk.t1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .settingsRow()
    }

    private func choiceRow<T: Equatable>(
        _ row: SettingsRow,
        label: String,
        choices: [(String, T)],
        selection: Binding<T>
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(draft.selectedRow == row ? tk.accent : tk.t1)
            Spacer()
            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                Button {
                    draft.selectedRow = row
                    selection.wrappedValue = choice.1
                    keyboardFocused = true
                } label: {
                    Text(choice.0)
                        .font(.callout)
                        .foregroundStyle(selection.wrappedValue == choice.1 ? tk.t1 : tk.t3)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(selection.wrappedValue == choice.1
                                    ? tk.accent.opacity(0.22) : tk.surf2,
                                    in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            draft.selectedRow = row
            keyboardFocused = true
        }
        .settingsRow()
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Spacer()
            actionButton("Cancel", action: .cancel, prominent: false)
            actionButton("Save", action: .save, prominent: true)
        }
        .settingsRow()
    }

    private func actionButton(
        _ title: String,
        action: SettingsAction,
        prominent: Bool
    ) -> some View {
        Button(title) {
            perform(action)
        }
        .buttonStyle(AyuButton(tk: tk, prominent: prominent))
        .focusable(false)
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .escape {
            perform(.cancel)
            return .handled
        }
        if press.key == .return {
            // The key row opens the key prompt rather than saving.
            if draft.selectedRow == .providerKey, activeProfile.needsKey {
                showingKeySheet = true
                return .handled
            }
            if let action = draft.handle(.activate) { perform(action) }
            return .handled
        }
        if press.modifiers.contains(.command) { return .ignored }
        if let character = press.characters.first,
           let key = settingsKey(for: character) {
            if let action = draft.handle(key) { perform(action) }
            return .handled
        }
        return press.characters.isEmpty ? .ignored : .handled
    }

    private func perform(_ action: SettingsAction) {
        switch action {
        case .cancel: model.modal = nil
        case .save: model.applySettings(draft.values)
        }
    }
}

private struct SettingsRowStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }
}

private extension View {
    func settingsRow() -> some View {
        modifier(SettingsRowStyle())
    }
}

/// Secure prompt to set or clear the active provider's API key (Keychain).
private struct ProviderKeySheet: View {
    let profile: ProviderProfile
    @Bindable var model: AppModel
    @Binding var isPresented: Bool

    @State private var key: String = ""
    @FocusState private var focused: Bool
    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(profile.label) API key").font(.headline)
            SecureField("", text: $key, prompt: Text("paste key"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
            HStack(spacing: 8) {
                if model.providerKeyIsSet(profile) {
                    Button("Clear") { model.setProviderKey(profile, ""); isPresented = false }
                        .buttonStyle(AyuButton(tk: tk, prominent: false))
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(AyuButton(tk: tk, prominent: false))
                Button("Save") {
                    model.setProviderKey(profile, key); isPresented = false
                }
                .buttonStyle(AyuButton(tk: tk, prominent: true))
                .disabled(key.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { focused = true }
    }
}
