import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var keyMonitor: Any?
    @State private var paletteState = CommandPaletteState()
    @State private var palettePreviousResponder: NSResponder?

    private var tokens: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        VStack(spacing: 0) {
            if model.showHeader {
                TopBar(model: model)
            }
            workspace
            if model.showFooter {
                StatusBar(model: model)
            }
        }
        .background {
            WindowBackdrop()
                .overlay(tokens.bg.opacity(Tokens.backdropTint))
                .ignoresSafeArea()
        }
        // The window uses fullSizeContentView: pull the topbar up into the
        // (transparent) title-bar zone so it shares the traffic-light row.
        .ignoresSafeArea(.container, edges: .top)
        // No system (blue) focus rings anywhere; the caret and our own field
        // styling carry focus. Inherited by every input in the hierarchy.
        .focusEffectDisabled()
        .installSubduedScrollbars()
        .preferredColorScheme(model.themeRaw == "light" ? .light : .dark)
        .tint(Tokens(Theme(raw: model.themeRaw)).accent)
        .sheet(item: $model.modal, onDismiss: { model.modalDidDismiss() }) { modal in
            Group {
                switch modal {
                case .settings: SettingsSheet(model: model)
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
            .installSubduedScrollbars()
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
                              glmUsage: model.glmUsage,
                              claudeUsageEnabled: model.claudeUsageEnabled,
                              codexUsageEnabled: model.codexUsageEnabled,
                              glmUsageEnabled: model.glmUsageEnabled,
                              onSetClaudeUsageEnabled: { model.setClaudeUsageEnabled($0) },
                              onSetCodexUsageEnabled: { model.setCodexUsageEnabled($0) },
                              onSetGlmUsageEnabled: { model.setGlmUsageEnabled($0) },
                              selectedProvider: model.limitsSelectedProvider,
                              tk: tokens)
                    .padding(.top, 42)
                    .offset(x: limitsOverlayHorizontalOffset(model.usagePlacement))
                    .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
                    .animation(.spring(response: 0.28, dampingFraction: 0.86), value: model.inputMode)
            }
        }
        .overlay {
            if model.commandPalettePresented {
                ZStack {
                    Color.black.opacity(0.36).ignoresSafeArea()
                    CommandPaletteView(model: model, state: $paletteState)
                }
            }
        }
        .onChange(of: model.commandPalettePresented) { _, presented in
            if presented {
                palettePreviousResponder = NSApp.keyWindow?.firstResponder
            } else {
                let responder = palettePreviousResponder
                palettePreviousResponder = nil
                DispatchQueue.main.async {
                    if model.modal == nil,
                       let window = NSApp.keyWindow,
                       let responder {
                        _ = window.makeFirstResponder(responder)
                    }
                    model.restoreCommandPaletteTerminalFocus()
                }
            }
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // ⌘W: kill sheet for the selected session (File→Close would
                // shadow a menu ⌘W — AppKit picks the first key equivalent).
                if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                   event.charactersIgnoringModifiers == "w" {
                    if model.commandPalettePresented { return nil }
                    guard model.modal == nil else { return event }
                    model.perform(.killSession)
                    return nil
                }
                // ⌘-anything else belongs to the menu system.
                guard !event.modifierFlags.contains(.command) else { return event }
                // The search field owns every non-Command key while the
                // palette is open; none may reach the workspace router.
                if model.commandPalettePresented { return event }
                // Inspector focus chords must escape its text fields: ⌃h/l
                // never type text (those emacs bindings are sacrificed).
                if model.focus == .inspector,
                   event.modifierFlags.intersection([.command, .shift, .option, .control]) == .control,
                   let raw = event.charactersIgnoringModifiers?.first,
                   ["h", "l"].contains(latinize(raw)) {
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

    /// Coordinate space the resize handles measure in: its origin is the
    /// window's content edge, which is what `PanelLayout` expects.
    static let workspaceSpace = "workspace"

    private var workspace: some View {
        GeometryReader { geo in
            let layout = PanelLayout.make(total: geo.size.width,
                                          showSessions: model.showSessions,
                                          showInspector: model.showInspector,
                                          splitPct: model.splitPct,
                                          sbWidth: model.sbWidth)
            HStack(spacing: 0) {
                if model.showSessions {
                    SessionListView(model: model)
                        .frame(width: layout.sessions)
                        .onTapGesture { model.setFocus(.sessions) }
                    divider(inner: layout.inner)
                }
                TerminalPaneView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { model.setFocus(.terminal) }
                if model.showInspector {
                    rightDivider(total: geo.size.width)
                    InspectorView(model: model)
                        .frame(width: layout.inspector)
                        .contentShape(Rectangle())
                        .onTapGesture { model.setFocus(.inspector) }
                }
            }
            // Vertically the top bar and the footer are the inset on their own
            // side, so the cards sit straight under them; a hidden bar hands
            // that side back to the edge token so a card never touches the
            // window frame. Horizontally the inset is unconditional —
            // `PanelLayout` subtracts exactly that much when it sizes the cards.
            .padding(.horizontal, Tokens.edge)
            .padding(.top, model.showHeader ? 0 : Tokens.edge)
            .padding(.bottom, model.showFooter ? 0 : Tokens.edge)
            .coordinateSpace(name: ContentView.workspaceSpace)
        }
    }

    private func rightDivider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: Tokens.gutter)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .named(ContentView.workspaceSpace))
                    .onChanged { value in
                        guard total > 0 else { return }
                        model.setSbWidth(PanelLayout.inspectorWidth(dragX: value.location.x,
                                                                    total: total))
                    }
            )
    }

    private func divider(inner: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: Tokens.gutter)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .named(ContentView.workspaceSpace))
                    .onChanged { value in
                        guard inner > 0 else { return }
                        model.setSplitPct(PanelLayout.splitPercent(dragX: value.location.x,
                                                                   inner: inner))
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
