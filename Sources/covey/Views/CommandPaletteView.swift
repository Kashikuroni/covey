import SwiftUI

struct CommandPaletteView: View {
    @Bindable var model: AppModel
    @Binding var state: CommandPaletteState
    @FocusState private var searchFocused: Bool

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }
    private var groups: [CommandSearchGroup] {
        CommandSearch.groups(query: state.query)
    }
    private var visible: [AppCommand] {
        groups.flatMap(\.matches).map(\.descriptor.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(tk.accent)

                TextField(
                    "Type a command…",
                    text: Binding(get: { state.query }, set: replaceQuery)
                )
                .textFieldStyle(.plain)
                .focused($searchFocused)

                KbdBadge(key: "esc", label: "close", tk: tk)
            }
            .padding(12)
            .overlay(alignment: .bottom) {
                Divider().overlay(tk.bd2)
            }

            if groups.isEmpty {
                Text("No matching commands")
                    .foregroundStyle(tk.t4)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(groups) { group in
                                Text(group.category.title.uppercased())
                                    .font(.caption2)
                                    .foregroundStyle(tk.t4)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 8)

                                ForEach(group.matches) { match in
                                    row(match.descriptor)
                                        .id(match.descriptor.id)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: state.selection) { _, selection in
                        guard let selection else { return }
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(selection, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 620)
        .background(tk.surface, in: RoundedRectangle(cornerRadius: Tokens.rLg))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.rLg).strokeBorder(tk.bd3)
        }
        .shadow(color: tk.shadowColor, radius: 24, y: 12)
        .onAppear {
            reset()
            DispatchQueue.main.async { searchFocused = true }
        }
        .onExitCommand { model.closeCommandPalette() }
        .onKeyPress(.downArrow) {
            move(1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            move(-1)
            return .handled
        }
        .onKeyPress(.return) {
            executeSelection()
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            guard press.modifiers == .control else { return .ignored }
            if press.key == "j" {
                move(1)
                return .handled
            }
            if press.key == "k" {
                move(-1)
                return .handled
            }
            return .ignored
        }
    }

    @ViewBuilder
    private func row(_ descriptor: CommandDescriptor) -> some View {
        let availability = model.commandAvailability(descriptor.id)

        Button {
            if availability.isEnabled { model.perform(descriptor.id) }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.title)
                        .foregroundStyle(availability.isEnabled ? tk.t1 : tk.t4)
                    if case .disabled(let reason) = availability {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(tk.err.opacity(0.8))
                    }
                }

                Spacer()

                if let shortcut = descriptor.shortcut {
                    Text(shortcut.display)
                        .font(.caption.monospaced())
                        .foregroundStyle(tk.t3)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                state.selection == descriptor.id ? tk.surf3 : .clear,
                in: RoundedRectangle(cornerRadius: Tokens.rSm)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(descriptor, availability))
    }

    private func reset() {
        let rows = CommandSearch.groups(query: "")
            .flatMap(\.matches).map(\.descriptor.id)
        state.reset(visible: rows) { model.commandAvailability($0).isEnabled }
    }

    private func replaceQuery(_ query: String) {
        let rows = CommandSearch.groups(query: query)
            .flatMap(\.matches).map(\.descriptor.id)
        state.replaceQuery(query, visible: rows) {
            model.commandAvailability($0).isEnabled
        }
    }

    private func move(_ delta: Int) {
        state.move(by: delta, visible: visible)
    }

    private func executeSelection() {
        guard let command = state.selection,
              model.commandAvailability(command).isEnabled else { return }
        model.perform(command)
    }

    private func accessibilityLabel(
        _ descriptor: CommandDescriptor,
        _ availability: CommandAvailability
    ) -> String {
        if case .disabled(let reason) = availability {
            return "\(descriptor.title), unavailable, \(reason)"
        }
        return descriptor.title
    }
}
