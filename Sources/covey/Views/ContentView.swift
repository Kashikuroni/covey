import SwiftUI

enum CommandWHandling: Equatable {
    case consume
    case perform(AppCommand)
}

func commandWHandling(focus: AppModel.Focus,
                      inputMode: InputMode,
                      modalPresented: Bool = false) -> CommandWHandling {
    guard !modalPresented else { return .consume }
    guard inputMode == .normal else { return .consume }
    return focus == .terminal ? .perform(.closeTerminalSplit) : .consume
}

func isCommandW(_ event: NSEvent) -> Bool {
    event.modifierFlags.intersection([.command, .shift, .option, .control, .function]) == .command
        && event.keyCode == 13 // kVK_ANSI_W — independent of the active layout
}

func shouldRestoreCommandPaletteResponder(inputMode: InputMode) -> Bool {
    inputMode != .limits
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var keyMonitor: Any?
    @State private var windowScope = WorkspaceWindowScope()
    @State private var paletteState = CommandPaletteState()
    @State private var palettePreviousResponder: NSResponder?

    private var tokens: Tokens { Tokens(Theme(raw: model.themeRaw)) }
    private var backgroundStyle: AppBackgroundStyle { AppBackgroundStyle(tokens: tokens) }

    var body: some View {
        VStack(spacing: 0) {
            if model.showHeader {
                TopBar(model: model)
            }
            mainArea
            if model.showFooter {
                StatusBar(model: model)
            }
        }
        .background {
            LinearGradient(colors: [backgroundStyle.leadingColor, backgroundStyle.trailingColor],
                           startPoint: backgroundStyle.startPoint,
                           endPoint: backgroundStyle.endPoint)
                .ignoresSafeArea()
        }
        // The window uses fullSizeContentView: pull the topbar up into the
        // (transparent) title-bar zone so it shares the traffic-light row.
        .ignoresSafeArea(.container, edges: .top)
        // No system (blue) focus rings anywhere; the caret and our own field
        // styling carry focus. Inherited by every input in the hierarchy.
        .focusEffectDisabled()
        .background { WorkspaceWindowReader(scope: windowScope) }
        .installSubduedScrollbars()
        .preferredColorScheme(model.themeRaw == "light" ? .light : .dark)
        .tint(Tokens(Theme(raw: model.themeRaw)).accent)
        .sheet(isPresented: $model.showProvidersPanel) {
            ProvidersPanel(model: model)
        }
        // Шторка настроек дашборда: поверх всего окна, справа, 2/5 ширины.
        .overlay {
            GeometryReader { geo in
                if model.showDashboardSettings {
                    ZStack(alignment: .trailing) {
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                            .onTapGesture { model.showDashboardSettings = false }
                        DashboardSettingsPanel(model: model,
                                               settings: model.dashboardSettings,
                                               tk: Tokens(Theme(raw: model.themeRaw))) {
                            model.showDashboardSettings = false
                        }
                        .frame(width: geo.size.width * 0.4)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    .animation(.easeInOut(duration: 0.18), value: model.showDashboardSettings)
                }
            }
        }
        .sheet(item: $model.modal, onDismiss: { model.modalDidDismiss() }) { modal in
            Group {
                switch modal {
                case .settings: SettingsSheet(model: model)
                case .newSession: NewSessionSheet(model: model)
                case .recent: RecentSheet(model: model)
                case .kill(let name): KillSheet(model: model, name: name)
                case .rename(let name): RenameSheet(model: model, name: name)
                case .renameProject(let dir): RenameProjectSheet(model: model, dir: dir)
                case .splitPicker(let axis): SplitPickerView(model: model, axis: axis)
                case .promote(let name): PromoteSheet(model: model, name: name)
                case .deleteBranch(let name): DeleteBranchSheet(model: model, name: name)
                case .cleanup(let dir): CleanupSheet(model: model, dir: dir)
                case .restart(let name): RestartSheet(model: model, name: name)
                case .restartAll: RestartAllSheet(model: model)
                case .themeRestart: ThemeRestartSheet(model: model)
                case .addProject: AddProjectSheet(model: model)
                case .logSearch: LogSearchSheet(model: model)
                }
            }
            .installSubduedScrollbars()
            // Sheets default to the system gray material — paint them ayu.
            .presentationBackground(tokens.surface)
        }
        .overlay(alignment: .bottom) { toastBar }
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
                LimitsPanel(model: model)
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
        .onChange(of: model.windowMode) { _, mode in
            // Nothing hidden may keep the keyboard: not a terminal, not the
            // sessions filter, not an inspector editor.
            if mode == .review { windowScope.window?.makeFirstResponder(nil) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let window = note.object as? NSWindow, window === windowScope.window else { return }
            model.setMainWindowOccluded(!window.occlusionState.contains(.visible))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // Back from another app: look for the agent's changes now.
            guard (note.object as? NSWindow) === windowScope.window,
                  model.windowMode == .review, let review = model.review else { return }
            Task { await review.checkFreshness() }
        }
        .onChange(of: model.commandPalettePresented) { _, presented in
            if presented {
                palettePreviousResponder = NSApp.keyWindow?.firstResponder
            } else {
                let responder = palettePreviousResponder
                palettePreviousResponder = nil
                DispatchQueue.main.async {
                    if model.windowMode == .sessions,
                       shouldRestoreCommandPaletteResponder(inputMode: model.inputMode),
                       model.modal == nil,
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
                handleKeyDown(event)
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    /// The window's one key monitor: Review's keys while Review is shown,
    /// the sessions' otherwise.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard windowScope.contains(event.window) else { return event }
        if model.windowMode == .review, let review = model.review {
            return handleReviewKey(event, review: review)
        }
        return handleSessionsKey(event)
    }

    /// Review's half (formerly the Review window's own monitor); the
    /// decision itself is `ReviewModeKeys.decide`.
    private func handleReviewKey(_ event: NSEvent, review: ReviewModel) -> NSEvent? {
        let responder = event.window?.firstResponder
        let flags = event.modifierFlags
        let input = ReviewModeKeyInput(
            key: ReviewKeyEvent(characters: event.charactersIgnoringModifiers ?? "",
                                isEscape: event.keyCode == 53,
                                command: flags.contains(.command),
                                control: flags.contains(.control),
                                option: flags.contains(.option)),
            isRepeat: event.isARepeat,
            isCommandW: isCommandW(event),
            fieldEditorFocused: (responder as? NSTextView)?.isFieldEditor == true,
            textInputFocused: responder is NSText,
            paletteOpen: model.commandPalettePresented,
            sheetOpen: model.modal != nil,
            appOverlayOpen: model.inputMode != .normal,
            reviewModalOpen: review.sendDraft != nil || review.keysOverlayOpen)
        switch ReviewModeKeys.decide(input) {
        case .pass:
            return event
        case .swallow:
            return nil
        case .endEditing:
            event.window?.makeFirstResponder(nil)
            return nil
        case .overlay:
            model.applyReviewOverlayKey(keyInput(from: event))
            return nil
        case .perform(.closeReview):
            Task { await model.leaveReview() }
            return nil
        case .perform(let action):
            Task { await review.perform(action) }
            return nil
        }
    }

    private func handleSessionsKey(_ event: NSEvent) -> NSEvent? {
        // Reserve physical ⌘W for Covey before AppKit can choose
        // File→Close: close a terminal split, consume it everywhere else.
        if isCommandW(event) {
            if model.commandPalettePresented { return nil }
            switch commandWHandling(focus: model.focus,
                                    inputMode: model.inputMode,
                                    modalPresented: model.modal != nil) {
            case .consume:
                return nil
            case .perform(let command):
                model.perform(command)
                return nil
            }
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
        // preview are not NSTextViews); only its global control chords
        // above escape into the app router.
        if model.focus == .inspector, model.inputMode == .normal {
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

    /// Review — and Forecast — lie over the sessions workspace, which stays
    /// mounted at its size — invisible and deaf to the mouse — so a mode
    /// switch resizes no terminal and no agent gets a SIGWINCH.
    private var mainArea: some View {
        let reviewing = model.windowMode == .review
        let forecasting = model.windowMode == .forecast
        return ZStack {
            workspace
                .opacity(reviewing || forecasting ? 0 : 1)
                .allowsHitTesting(!(reviewing || forecasting))
                .accessibilityHidden(reviewing || forecasting)
            if reviewing, let review = model.review {
                ReviewModeView(model: review, app: model)
                    // A replaced review is a new view: none of the old one's
                    // state, change handlers or poll loop carries over.
                    .id(ObjectIdentifier(review))
                    .padding(.horizontal, Tokens.edge)
                    .padding(.top, model.showHeader ? 0 : Tokens.edge)
                    .padding(.bottom, model.showFooter ? 0 : Tokens.edge)
            }
            if forecasting {
                ForecastModeView(model: model)
                    .padding(.horizontal, Tokens.edge)
                    .padding(.top, model.showHeader ? 0 : Tokens.edge)
                    .padding(.bottom, model.showFooter ? 0 : Tokens.edge)
            }
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
