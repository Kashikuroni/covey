import AppKit
import SwiftUI
import SwiftTerm

/// First installed Nerd Font, or nil (SwiftTerm keeps its default). Names are
/// PostScript names across Nerd Fonts v2/v3 packagings.
func nerdFont(size: CGFloat) -> NSFont? {
    let candidates = [
        "JetBrainsMonoNerdFont-Regular",   // v3
        "JetBrainsMonoNF-Regular",
        "JetBrainsMono Nerd Font",
        "MesloLGSNerdFont-Regular",
        "MesloLGS-NF-Regular",
        "MesloLGS NF",
        "HackNerdFont-Regular",
        "Hack Nerd Font",
        "FiraCodeNerdFont-Regular",
        "FiraCode Nerd Font",
    ]
    for name in candidates {
        if let f = NSFont(name: name, size: size) { return f }
    }
    return nil
}

/// URL for a terminal-reported link click. Only web schemes open: a TUI
/// can emit arbitrary OSC 8 targets, and file:/javascript: must not get
/// click-to-open semantics.
func linkURL(from link: String) -> URL? {
    guard let url = URL(string: link),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else { return nil }
    return url
}

/// SwiftTerm TerminalView bridged into SwiftUI, render-only: the daemon owns
/// the process. Keystrokes go to the daemon (`send` -> input), bytes come back
/// through the model's per-name terminal sink. The hosting view remounts this
/// per session via `.id(sessionName)`.
struct TerminalRepresentable: NSViewRepresentable {
    let model: AppModel
    let name: String

    func makeCoordinator() -> Coordinator { Coordinator(model: model, name: name) }

    func makeNSView(context: Context) -> TerminalView {
        let view = CoveyTerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        // Claude panes are keyboard-first: never forward mouse to the agent, so
        // a click/drag focuses and selects text locally instead of hijacking
        // Claude's mouse-interactive prompt (accidental option pick). Shell
        // companions keep mouse reporting for vim/lazygit.
        view.allowMouseReporting = !model.agentIsClaude(self.name)
        // Nerd Font when installed: nvim/lazygit icon glyphs live in the
        // private-use area that stock Menlo lacks (tofu boxes otherwise).
        if let nerd = nerdFont(size: view.font.pointSize) {
            view.font = nerd
        }
        // Claude repaints each frame atomically inside one DECSET 2026 sync
        // block, so render it immediately. SwiftTerm otherwise defers the frame
        // until `syncSequenceSettleMs` after the LAST sync block and cancels the
        // render when the next block opens — so a continuous scroll (a stream of
        // sync blocks) renders NOTHING until the gesture settles, then snaps to
        // the destination (visible freeze-then-jump). Non-claude panes keep the
        // default: tmux/vim split one repaint across several sync pairs and need
        // the coalescing to avoid tearing.
        view.syncSequenceSettleMs = model.agentIsClaude(self.name) ? 0 : 16
        let model = self.model
        let name = self.name
        // Entering/leaving the alternate buffer invalidates any scrolled-up
        // viewport, so a stale HISTORY badge must clear.
        view.onBufferSwitch = { Task { @MainActor in model.setHistoryMode(false) } }
        view.onFocusRequest = { Task { @MainActor in model.focusPane(name) } }
        view.onWheelScroll = { Task { @MainActor in model.requestTerminalRefresh(name) } }
        model.setTerminalCommandHandler(for: name) { [weak view] command in
            guard let view else { return }
            switch command {
            case .focus:
                view.window?.makeFirstResponder(view)
            case .blur:
                view.window?.makeFirstResponder(nil)
            case .scrollPage(let up):
                if up { view.scrollUp(lines: 10) } else { view.scrollDown(lines: 10) }
            case .scrollToBottom:
                view.scroll(toPosition: 1.0)
            }
        }
        applyTheme(to: view)
        model.setTerminalSink(for: name) { [weak view] bytes in
            view?.feed(byteArray: bytes[...])
        }
        // A structural remount (split toggle) built a fresh emulator: ask the
        // daemon to replay the session state (preamble + backfill) into it.
        model.paneViewMounted(name)
        // A freshly mounted pane that already owns the pane focus grabs the
        // keyboard (companion created via space t v).
        if model.focusedPane == name, model.focus == .terminal {
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                view.window?.makeFirstResponder(view)
            }
        }
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        applyTheme(to: view)
        // The session list may have been empty when makeNSView first ran
        // (claude-ness unknown → mouse reporting left on). Re-evaluate now that
        // the sessions are loaded so claude panes reliably suppress the mouse.
        view.allowMouseReporting = !model.agentIsClaude(name)
        view.syncSequenceSettleMs = model.agentIsClaude(name) ? 0 : 16
    }

    private func applyTheme(to view: TerminalView) {
        let theme = Theme(raw: model.themeRaw)
        view.nativeBackgroundColor = theme.background
        view.nativeForegroundColor = theme.foreground
        view.caretColor = theme.cursor
        // 16 ANSI colors; SwiftTerm expects its own Color type (16-bit channels).
        view.installColors(theme.ansi.map { c in
            let rgb = c.usingColorSpace(.sRGB) ?? c
            return SwiftTerm.Color(red: UInt16(rgb.redComponent * 65535),
                                   green: UInt16(rgb.greenComponent * 65535),
                                   blue: UInt16(rgb.blueComponent * 65535))
        })
    }

    // No teardown of the model's sink here: sessions switch by remounting
    // (`.id`), and makeNSView of the new terminal overwrites the sink. Nil-ing it
    // asynchronously on dismantle could race and clear the new view's sink. The
    // old closure captures `[weak view]`, so it harmlessly no-ops after teardown.

    // Not MainActor-isolated: TerminalViewDelegate requirements are nonisolated,
    // so an isolated class could not satisfy them. Calls hop to the actor inside.
    final class Coordinator: TerminalViewDelegate {
        let model: AppModel
        let name: String
        init(model: AppModel, name: String) { self.model = model; self.name = name }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            Task { @MainActor in await model.sendInput(bytes, to: name) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            let (cols, rows) = (UInt16(newCols), UInt16(newRows))
            Task { @MainActor in await model.resize(cols: cols, rows: rows, name: name) }
        }

        func scrolled(source: TerminalView, position: Double) {
            // Alternate-buffer region scrolls (a streaming TUI) fire this with
            // position 0 (Terminal.scroll always notifies; alt scrollPosition
            // is 0) — history mode does not apply there.
            if source.getTerminal().isCurrentBufferAlternate {
                Task { @MainActor in model.setHistoryMode(false) }
                return
            }
            // SwiftTerm's scroll(toPosition:) truncates, so a scrollbar drag can
            // land one line short of the live bottom and pin the HISTORY badge;
            // snap that last line (scroll(toPosition: 1.0) hits the exact bottom
            // and re-fires scrolled with 1.0). Only while the left button is
            // down (an actual scroller drag): wheel scrolling moves in exact
            // single lines and must be able to REST one line up, and inline
            // claude's constant repaints re-fire scrolled — snapping there
            // yanks a slow upward scroll straight back to the bottom.
            if linesShortOfBottom(position: position,
                                  yDisp: source.getTerminal().buffer.yDisp) == 1,
               NSEvent.pressedMouseButtons & 1 == 1 {
                DispatchQueue.main.async { [weak source] in source?.scroll(toPosition: 1.0) }
                return
            }
            // position 1.0 == pinned to the live bottom; anything less is history.
            let history = position < 0.999
            Task { @MainActor in model.setHistoryMode(history) }
        }

        // The daemon owns process state; the rest of the delegate is unused.
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        // Inline-mode claude doesn't own the mouse, so the GUI opens link
        // clicks (alt-screen TUIs handled them via mouse reporting).
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = linkURL(from: link) else { return }
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
