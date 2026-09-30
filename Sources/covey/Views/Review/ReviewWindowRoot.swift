import SwiftUI
import AppKit
import CoveyGit
import CoveyKit

/// Ends text editing (the path filter, the composer) so the review keys
/// reach the key monitor again. Called by clicks on cards, tree rows and
/// the canvas, which take no focus themselves.
@MainActor
func resignReviewTextFocus() {
    NSApp.keyWindow?.makeFirstResponder(nil)
}

/// Scene content of one Review window.
struct ReviewWindowRoot: View {
    let key: ReviewWindowKey
    let app: AppModel
    @State private var model: ReviewModel?

    var body: some View {
        Group {
            if let model {
                ReviewWindowView(model: model, app: app)
            } else {
                ProgressView().frame(minWidth: 900, minHeight: 600)
            }
        }
        .task {
            guard model == nil else { return }
            let launch = app.reviewLaunch(for: key)
            let created = ReviewModel(worktree: key.worktree,
                                      projectRoot: launch?.projectRoot ?? projectRoot(key.worktree),
                                      originSession: launch?.originSession,
                                      git: ReviewGitService(), store: .shared, directory: app)
            model = created
            await created.start()
        }
    }
}

struct ReviewWindowView: View {
    @Bindable var model: ReviewModel
    let app: AppModel
    @State private var scope = WorkspaceWindowScope()
    @State private var keyMonitor: Any?
    /// This window is the main window. `app.reviewWindowFocused` is one flag
    /// for all Review windows, so a window only clears it when it set it.
    /// Main, not key: the comparison popover is a window of its own that
    /// takes key status, but popovers and sheets never become main.
    @State private var isMain = false
    @State private var diffFraction: CGFloat = 0.55
    @State private var dragStartFraction: CGFloat?

    private var tk: Tokens { Tokens(Theme(raw: app.themeRaw)) }

    var body: some View {
        VStack(spacing: 0) {
            ReviewTopBar(model: model, tk: tk)
            if let banner = model.banner {
                ReviewBanner(text: banner, tk: tk) { Task { await model.retry() } }
            }
            content
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(tk.bg)
        .overlay { if model.sendDraft != nil { ReviewSendSheet(model: model, tk: tk) } }
        .overlay {
            if model.keysOverlayOpen {
                ReviewKeysOverlay(tk: tk) { model.keysOverlayOpen = false }
            }
        }
        .overlay(alignment: .bottom) { ReviewToastStack(toasts: model.toasts, tk: tk) }
        // Native controls (pickers, text fields, the composer) follow covey's
        // theme, not the macOS appearance.
        .preferredColorScheme(app.themeRaw == "light" ? .light : .dark)
        .tint(tk.accent)
        .background { WorkspaceWindowReader(scope: scope) }
        .navigationTitle("Review · \(projectDefaultName(model.projectRoot))")
        .task { await model.runPolling() }
        .onAppear {
            installKeyMonitor()
            // The window usually became main while the model was still loading,
            // before this view could hear the notification.
            Task { @MainActor in syncMainState() }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            if isMain {
                isMain = false
                app.reviewWindowFocused = false
            }
            model.flush()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard scope.contains(note.object as? NSWindow) else { return }
            Task { await model.checkFreshness() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { note in
            guard scope.contains(note.object as? NSWindow) else { return }
            isMain = true
            app.reviewWindowFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignMainNotification)) { note in
            guard scope.contains(note.object as? NSWindow) else { return }
            isMain = false
            app.reviewWindowFocused = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let window = note.object as? NSWindow, scope.contains(window) else { return }
            model.isVisible = window.occlusionState.contains(.visible)
        }
        .onChange(of: model.target?.status) { old, new in
            Task { await model.targetStatusChanged(from: old, to: new) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missingWorktree:
            ReviewEmptyState(title: "Worktree not found",
                             message: "\(model.worktree) is gone or is not a Git repository.", tk: tk)
        case .needsComparison, .ready:
            GeometryReader { geo in
                HStack(spacing: 0) {
                    if model.sidebarVisible { ReviewSidebar(model: model, tk: tk) }
                    ReviewCanvas(model: model, tk: tk)
                    if model.diffOpen, model.selectedPath != nil {
                        resizeHandle(total: geo.size.width)
                        ReviewDiffPanel(model: model, tk: tk)
                            .frame(width: max(380, geo.size.width * diffFraction))
                    }
                }
            }
        }
    }

    private func resizeHandle(total: CGFloat) -> some View {
        Rectangle()
            .fill(tk.bd2)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    // Global space: the handle itself moves as the fraction
                    // changes, so a local translation would chase its own tail.
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            if dragStartFraction == nil { dragStartFraction = diffFraction }
                            let proposed = dragStartFraction! - value.translation.width / max(total, 1)
                            diffFraction = min(max(proposed, 0.3), 0.8)
                        }
                        .onEnded { _ in dragStartFraction = nil })
            }
    }

    private func syncMainState() {
        guard !isMain, let window = scope.window, window.isMainWindow else { return }
        isMain = true
        app.reviewWindowFocused = true
    }

    /// Window-scoped like ContentView's monitor; text fields keep their keys.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard scope.contains(event.window) else { return event }
            // Esc in a text field (the path filter) only ends editing there:
            // routed, it would close the diff or drop a composer draft while
            // the field kept focus. The composer's TextEditor is not a field
            // editor, so Esc there still unwinds as usual.
            if event.keyCode == 53, (event.window?.firstResponder as? NSTextView)?.isFieldEditor == true {
                event.window?.makeFirstResponder(nil)
                return nil
            }
            let flags = event.modifierFlags
            let key = ReviewKeyEvent(characters: event.charactersIgnoringModifiers ?? "",
                                     isEscape: event.keyCode == 53,
                                     command: flags.contains(.command),
                                     control: flags.contains(.control),
                                     option: flags.contains(.option))
            let context = ReviewKeyContext(textInputFocused: event.window?.firstResponder is NSText,
                                           modalOpen: model.sendDraft != nil || model.keysOverlayOpen)
            guard let action = ReviewKeyRouter.route(key, context: context) else { return event }
            if action == .closeReview {
                event.window?.performClose(nil)
                return nil
            }
            // Holding R / E / ? must not flip-flop the state.
            if event.isARepeat, action == .toggleReviewed || action == .toggleFullFile || action == .showKeys {
                return nil
            }
            Task { await model.perform(action) }
            return nil
        }
    }
}
