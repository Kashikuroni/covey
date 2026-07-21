import AppKit
import SwiftTerm
@testable import covey

final class TerminalInputProbe: TerminalViewDelegate {
    var sent = [UInt8]()

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sent += Array(data)
    }

    func scrolled(source: TerminalView, position: Double) {}
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func requestOpenLink(source: TerminalView, link: String,
                         params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor
@discardableResult
func hostTerminalForKeyboardInput(_ view: CoveyTerminalView) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.contentView = view
    _ = window.makeFirstResponder(view)
    return window
}

@MainActor
func sendReturnKey(to view: CoveyTerminalView,
                   modifiers: NSEvent.ModifierFlags = []) {
    precondition(view.window != nil, "host the terminal before sending AppKit input")
    let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: view.window!.windowNumber,
        context: nil,
        characters: "\r",
        charactersIgnoringModifiers: "\r",
        isARepeat: false,
        keyCode: 36
    )!
    view.keyDown(with: event)
}
