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
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        // Hardcoded dark theme (HANDOFF §5); theme switching arrives in slice 6.
        view.nativeBackgroundColor = NSColor(red: 0x1C / 255, green: 0x19 / 255,
                                             blue: 0x17 / 255, alpha: 1)
        view.nativeForegroundColor = NSColor(red: 0xFA / 255, green: 0xF7 / 255,
                                             blue: 0xF2 / 255, alpha: 1)
        view.caretColor = .orange
        model.onTerminalOutput = { [weak view] bytes in
            view?.feed(byteArray: bytes[...])
        }
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {}

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

        // The daemon owns process state; the rest of the delegate is unused.
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
