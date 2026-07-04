import AppKit
import SwiftUI
import SwiftTerm

/// SwiftTerm TerminalView bridged into SwiftUI, render-only: the daemon owns
/// the process. Keystrokes go to the daemon (`send` -> input), bytes come back
/// through `model.onTerminalOutput`. The hosting view remounts this per
/// session via `.id(sessionName)`.
struct TerminalRepresentable: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> TerminalView {
        let view = CoveyTerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        let model = self.model
        // Entering/leaving the alternate buffer invalidates any scrolled-up
        // viewport, so a stale HISTORY badge must clear.
        view.onBufferSwitch = { Task { @MainActor in model.setHistoryMode(false) } }
        view.onFocusClick = { Task { @MainActor in model.setFocus(.terminal) } }
        model.onTerminalCommand = { [weak view] command in
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
        model.onTerminalOutput = { [weak view] bytes in
            view?.feed(byteArray: bytes[...])
        }
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        applyTheme(to: view)
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

    // No teardown of `model.onTerminalOutput` here: sessions switch by remounting
    // (`.id`), and makeNSView of the new terminal overwrites the sink. Nil-ing it
    // asynchronously on dismantle could race and clear the new view's sink. The
    // old closure captures `[weak view]`, so it harmlessly no-ops after teardown.

    // Not MainActor-isolated: TerminalViewDelegate requirements are nonisolated,
    // so an isolated class could not satisfy them. Calls hop to the actor inside.
    final class Coordinator: TerminalViewDelegate {
        let model: AppModel
        init(model: AppModel) { self.model = model }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            Task { @MainActor in await model.sendInput(bytes) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            let (cols, rows) = (UInt16(newCols), UInt16(newRows))
            Task { @MainActor in await model.resize(cols: cols, rows: rows) }
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
            // and re-fires scrolled with 1.0).
            if linesShortOfBottom(position: position,
                                  yDisp: source.getTerminal().buffer.yDisp) == 1 {
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
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
