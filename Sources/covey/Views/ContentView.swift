import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var keyMonitor: Any?

    private var tokens: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        VStack(spacing: 0) {
            if model.showHeader {
                TopBar(model: model)
                tokens.bd.frame(height: 1)
            }
            workspace
            if model.showFooter {
                tokens.bd.frame(height: 1)
                StatusBar(model: model)
            }
        }
        .background(tokens.bg)
        // The window uses fullSizeContentView: pull the topbar up into the
        // (transparent) title-bar zone so it shares the traffic-light row.
        .ignoresSafeArea(.container, edges: .top)
        // No system (blue) focus rings anywhere; the caret and our own field
        // styling carry focus. Inherited by every input in the hierarchy.
        .focusEffectDisabled()
        .preferredColorScheme(model.themeRaw == "light" ? .light : .dark)
        .tint(Tokens(Theme(raw: model.themeRaw)).accent)
        .sheet(item: $model.modal) { modal in
            Group {
                switch modal {
                case .newSession: NewSessionSheet(model: model)
                case .recent: RecentSheet(model: model)
                case .kill(let name): KillSheet(model: model, name: name)
                case .rename(let name): RenameSheet(model: model, name: name)
                case .renameProject(let dir): RenameProjectSheet(model: model, dir: dir)
                case .promote(let name): PromoteSheet(model: model, name: name)
                case .deleteBranch(let name): DeleteBranchSheet(model: model, name: name)
                case .cleanup(let dir): CleanupSheet(model: model, dir: dir)
                case .restart(let name): RestartSheet(model: model, name: name)
                case .restartAll: RestartAllSheet(model: model)
                case .themeRestart: ThemeRestartSheet(model: model)
                case .addProject: AddProjectSheet(model: model)
                }
            }
            // Sheets default to the system gray material — paint them ayu.
            .presentationBackground(tokens.surface)
        }
        .overlay(alignment: .bottom) { toastBar }
        .overlay(alignment: .bottom) {
            if case .leader(let menu) = model.inputMode {
                WhichKeyView(menu: menu).padding(.bottom, 36)
            }
        }
        .overlay {
            if model.inputMode == .help { HelpOverlay(tk: tokens) }
        }
        // Click anywhere outside the limits popover closes it — added below
        // the popover itself in this call chain so the popover's own taps
        // are not swallowed by this catcher (later `.overlay` calls draw on
        // top, so this one, added first, sits underneath).
        .overlay {
            if model.inputMode == .limits {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.apply(.closeOverlay) }
            }
        }
        .overlay(alignment: topOverlayAlignment(model.usagePlacement)) {
            if model.inputMode == .limits {
                LimitsOverlay(usage: model.usage, plan: model.plan, error: model.usageError,
                              codexUsage: model.codexUsage, codexPlan: model.codexPlan,
                              claudeUsageEnabled: model.claudeUsageEnabled,
                              codexUsageEnabled: model.codexUsageEnabled,
                              onSetClaudeUsageEnabled: { model.setClaudeUsageEnabled($0) },
                              onSetCodexUsageEnabled: { model.setCodexUsageEnabled($0) },
                              selectedProvider: model.limitsSelectedProvider,
                              tk: tokens)
                    .padding(.top, 42)
                    .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
                    .animation(.spring(response: 0.28, dampingFraction: 0.86), value: model.inputMode)
            }
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
                // Inspector zone chords must escape its text fields: ⌃h/l/j/k
                // never type text (the zone's emacs bindings are sacrificed).
                if model.focus == .inspector,
                   event.modifierFlags.intersection([.command, .shift, .option, .control]) == .control,
                   let raw = event.charactersIgnoringModifiers?.first,
                   ["h", "l", "j", "k"].contains(latinize(raw)) {
                    let context = KeyRouter.Context(mode: model.inputMode,
                                                    focus: model.focus,
                                                    vimMode: model.vimMode,
                                                    sheetOpen: model.modal != nil)
                    if let action = KeyRouter.route(keyInput(from: event), context: context) {
                        model.apply(action)
                        return nil
                    }
                }
                // The inspector zone owns its plain keys (vim editors and the
                // preview are not NSTextViews): only the zone chords above and
                // the space leader stay global here. The label checklist's
                // Space toggle sacrifices the leader instead, but only while
                // the issue editor screen owns the inspector.
                let plainChar = event.charactersIgnoringModifiers?.first.map(latinize)
                let issueEditOwnsSpace: Bool = {
                    guard model.issueScreen == .browser else { return false }
                    if case .edit = model.issueBrowser.screen { return true }
                    return false
                }()
                if model.focus == .inspector, model.inputMode == .normal,
                   plainChar != " " || issueEditOwnsSpace {
                    return event
                }
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
            .fill(Color.clear)
            .frame(width: 6)
            .overlay(Rectangle().fill(Color.gray.opacity(0.25)).frame(width: 1))
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
            .fill(Color.clear)
            .frame(width: 6)
            .overlay(Rectangle().fill(Color.gray.opacity(0.25)).frame(width: 1))
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
            .glassEffect(.regular, in: .rect(cornerRadius: 8))
            .padding(.bottom, 12)
        }
    }
}
