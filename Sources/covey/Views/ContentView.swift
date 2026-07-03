import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            if model.showHeader { TopBar(model: model); Divider() }
            workspace
            if model.showFooter { Divider(); StatusBar(model: model) }
        }
        .preferredColorScheme(model.themeRaw == "light" ? .light : .dark)
        .sheet(item: $model.modal) { modal in
            switch modal {
            case .newSession: NewSessionSheet(model: model)
            case .kill(let name): KillSheet(model: model, name: name)
            case .rename(let name): RenameSheet(model: model, name: name)
            case .renameProject(let dir): RenameProjectSheet(model: model, dir: dir)
            case .promote(let name): PromoteSheet(model: model, name: name)
            case .deleteBranch(let name): DeleteBranchSheet(model: model, name: name)
            case .cleanup(let dir): CleanupSheet(model: model, dir: dir)
            }
        }
        .overlay(alignment: .bottom) { toastBar }
        .overlay(alignment: .bottom) {
            if case .leader(let menu) = model.inputMode {
                WhichKeyView(menu: menu).padding(.bottom, 36)
            }
        }
        .overlay {
            if model.inputMode == .help { HelpOverlay() }
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // ⌘W: kill sheet for the selected session (File→Close would
                // shadow a menu ⌘W — AppKit picks the first key equivalent).
                if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                   event.charactersIgnoringModifiers == "w" {
                    guard model.modal == nil, let selected = model.selected else { return event }
                    model.modal = .kill(selected)
                    return nil
                }
                // ⌘-anything else belongs to the menu system.
                guard !event.modifierFlags.contains(.command) else { return event }
                // While a text field edits (filter, sheets), keys are its own.
                if let responder = event.window?.firstResponder, responder is NSTextView {
                    return event
                }
                let context = KeyRouter.Context(mode: model.inputMode,
                                                focus: model.focus,
                                                vimMode: model.vimMode,
                                                sheetOpen: model.modal != nil)
                guard let action = KeyRouter.route(keyInput(from: event), context: context) else {
                    return event
                }
                model.apply(action)
                return nil
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    private var workspace: some View {
        GeometryReader { geo in
            let leftWidth = max(220, min(geo.size.width - 480,
                                         geo.size.width * CGFloat(model.splitPct) / 100))
            HStack(spacing: 0) {
                if model.showSessions {
                    SessionListView(model: model)
                        .frame(width: leftWidth)
                        .onTapGesture { model.setFocus(.sessions) }
                    divider(total: geo.size.width)
                }
                TerminalPaneView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { model.setFocus(.terminal) }
                if model.showInspector {
                    rightDivider(total: geo.size.width)
                    InspectorView(model: model)
                        .frame(width: CGFloat(model.sbWidth))
                        .contentShape(Rectangle())
                        .onTapGesture { model.setFocus(.inspector) }
                }
            }
        }
    }

    private func rightDivider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color.gray.opacity(0.25))
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        guard total > 0 else { return }
                        model.setSbWidth(Int(total - value.location.x))
                    }
            )
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color.gray.opacity(0.25))
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        guard total > 0 else { return }
                        model.setSplitPct(Int(value.location.x / total * 100))
                    }
            )
    }

    private func keyInput(from event: NSEvent) -> KeyInput {
        let specials: [UInt16: Special] = [
            53: .escape, 36: .enter, 48: .tab, 51: .backspace,
            126: .up, 125: .down, 123: .left, 124: .right,
            116: .pageUp, 121: .pageDown, 119: .end,
        ]
        let flags = event.modifierFlags
        return KeyInput(
            char: event.charactersIgnoringModifiers?.first,
            isControl: flags.contains(.control),
            isShift: flags.contains(.shift),
            special: specials[event.keyCode]
        )
    }

    @ViewBuilder
    private var toastBar: some View {
        if let toast = model.toast {
            HStack(spacing: 12) {
                Text(toast).lineLimit(2)
                if !model.connected {
                    Button("Reconnect") { Task { await model.reconnect() } }
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 12)
        }
    }
}
