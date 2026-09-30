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

/// Review inside the main window (Review spec, part 1): top bar, banner,
/// file tree, canvas and diff panel, laid over the hidden sessions
/// workspace. Plan E grows the canvas; this view only frames it. Keys come
/// from `ContentView`'s monitor, the theme from the main window.
///
/// `ContentView` mounts it only while Review is shown, so the poll loop
/// lives exactly as long as the review is on screen; the loop is also keyed
/// by the model, so a replaced review's loop is cancelled, never inherited.
struct ReviewModeView: View {
    @Bindable var model: ReviewModel
    let app: AppModel
    @State private var dragStartFraction: CGFloat?

    private var tk: Tokens { Tokens(Theme(raw: app.themeRaw)) }

    var body: some View {
        VStack(spacing: 0) {
            ReviewTopBar(model: model, tk: tk) {
                ReviewWorktreePicker(app: app, review: model, tk: tk)
            }
            if let banner = model.banner {
                ReviewBanner(text: banner, tk: tk) { Task { await model.retry() } }
            }
            content
        }
        // Exactly the slot it is given: a wide top bar must not push the
        // window's content (and with it the hidden terminals) wider.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .overlay { if model.sendDraft != nil { ReviewSendSheet(model: model, tk: tk) } }
        .overlay {
            if model.keysOverlayOpen {
                ReviewKeysOverlay(tk: tk) { model.keysOverlayOpen = false }
            }
        }
        .overlay(alignment: .bottom) { ReviewToastStack(toasts: model.toasts, tk: tk) }
        .panelCard(tk, surface: tk.bg)
        .task(id: ObjectIdentifier(model)) { await model.runPolling() }
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
                            .frame(width: max(380, geo.size.width * model.diffFraction))
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
                            if dragStartFraction == nil { dragStartFraction = model.diffFraction }
                            let proposed = dragStartFraction! - value.translation.width / max(total, 1)
                            model.diffFraction = min(max(proposed, 0.3), 0.8)
                        }
                        .onEnded { _ in dragStartFraction = nil })
            }
    }
}
