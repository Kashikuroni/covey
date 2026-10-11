import XCTest
import SwiftUI
import WebKit
import Observation
import CoveyKit
@testable import covey

@Observable @MainActor private final class RenderTestState {
    var presentation: DocumentPresentation
    var command: DocumentRenderCommand?
    var position: DocumentPosition?
    @ObservationIgnored var lastPosition: DocumentPosition?
    @ObservationIgnored var findCount = 0
    init(_ presentation: DocumentPresentation) { self.presentation = presentation }
}
private struct RenderTestHost: View {
    let state: RenderTestState
    var body: some View {
        DocumentRenderedView(presentation:state.presentation,command:state.command,position:state.position) { event in
            if case .position(let position) = event { state.lastPosition = position }
            if case .findResult(_,let count) = event { state.findCount = count }
        }
    }
}
@MainActor final class DocumentRenderedViewTests: XCTestCase {
    private func webView(in root: NSView) -> WKWebView? {
        if let web = root as? WKWebView { return web }
        for child in root.subviews { if let web = webView(in:child) { return web } }
        return nil
    }
    private func waitForDOM(_ web: WKWebView, _ expression: String) async -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if (try? await web.evaluateJavaScript(expression)) as? Bool == true { return true }
            try? await Task.sleep(for:.milliseconds(30))
        }
        return false
    }
    func testOfflineRendererImagesFindSelectionAndPositionRestore() async throws {
        _ = NSApplication.shared
        let root = try XCTUnwrap(Bundle.module.url(forResource:"Documents",withExtension:nil))
        let source = try String(contentsOf:root.appendingPathComponent("reader.md"),encoding:.utf8)
        let context = DocumentContext(sourceSession:"s",root:root.path,projectKey:root.path)
        let state = RenderTestState(.init(text:source,path:"reader.md",context:context,sourceMode:false))
        let host = NSHostingView(rootView:RenderTestHost(state:state))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:480,height:260),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        let mounted = await eventually { self.webView(in:host) != nil }; XCTAssertTrue(mounted)
        let web = try XCTUnwrap(webView(in:host))
        let rendered = await waitForDOM(web,"document.querySelectorAll('table').length === 1 && document.querySelector('img')?.naturalWidth === 1")
        XCTAssertTrue(rendered,"Bundled JS/CSS and validated local image must work offline")
        let safe = try await web.evaluateJavaScript("!window.projectCodeMustNotRun && document.querySelectorAll('input[disabled]').length === 2 && document.querySelectorAll('.token').length > 0") as? Bool
        XCTAssertEqual(safe,true)
        let selected = try await web.evaluateJavaScript("(() => { const r=document.createRange();r.selectNodeContents(document.getElementById('document'));const s=getSelection();s.removeAllRanges();s.addRange(r);return s.toString().includes('Selected text can span paragraphs'); })()") as? Bool
        XCTAssertEqual(selected,true)
        state.command = .init(action:.find(query:"Selected text",backwards:false))
        let found = await eventually { state.findCount == 1 }; XCTAssertTrue(found)
        state.command = .init(action:.revealAnchor("повтор-1"))
        let previous = state.lastPosition
        let positioned = await eventually { state.lastPosition != previous }; XCTAssertTrue(positioned,"Position: \(String(describing:state.lastPosition))")
        let before = try XCTUnwrap(state.lastPosition)
        state.position = before
        state.presentation = .init(text:"# Inserted\n\nBefore the document.\n\n"+source,path:"reader.md",context:context,sourceMode:false)
        let anchorJSON = String(data:try JSONSerialization.data(withJSONObject:before.anchorID ?? "",options:.fragmentsAllowed),encoding:.utf8)!
        let restored = await waitForDOM(web,"Math.abs(document.getElementById(\(anchorJSON)).getBoundingClientRect().top + \(before.offset)) < 3")
        XCTAssertTrue(restored)
    }
}
