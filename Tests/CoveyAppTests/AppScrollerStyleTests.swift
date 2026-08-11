import AppKit
import SwiftUI
import XCTest
@testable import covey

@MainActor
final class AppScrollerStyleTests: XCTestCase {
    func testApplyUsesMiniSubduedScrollerChrome() {
        let scroller = NSScroller(frame: .zero)

        AppScrollerStyle.apply(to: scroller)

        XCTAssertEqual(scroller.controlSize, .mini)
        XCTAssertEqual(scroller.alphaValue, 0.45, accuracy: 0.001)
    }

    func testApplyRecursivelyStylesEveryScrollerUnderRoot() {
        let root = NSView(frame: .zero)
        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        root.addSubview(scrollView)
        let standalone = NSScroller(frame: .zero)
        root.addSubview(standalone)

        AppScrollerStyle.applyRecursively(in: root)

        XCTAssertEqual(scrollView.verticalScroller?.controlSize, .mini)
        XCTAssertEqual(scrollView.verticalScroller?.alphaValue ?? 1, 0.45, accuracy: 0.001)
        XCTAssertEqual(scrollView.horizontalScroller?.controlSize, .mini)
        XCTAssertEqual(scrollView.horizontalScroller?.alphaValue ?? 1, 0.45, accuracy: 0.001)
        XCTAssertEqual(standalone.controlSize, .mini)
        XCTAssertEqual(standalone.alphaValue, 0.45, accuracy: 0.001)
    }

    func testSubduedScrollViewStylesContainerMountedByDescendantStateChange() async {
        let state = DynamicScrollState()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(
            rootView: DynamicScrollRoot(state: state)
        )
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let initialStyled = await eventually {
            guard let root = window.contentView else { return false }
            let scrollViews = self.scrollViews(in: root)
            return scrollViews.count == 1
                && scrollViews.allSatisfy(self.isStyled)
        }
        XCTAssertTrue(initialStyled)

        state.showsScrollView = true

        let styled = await eventually {
            guard let root = window.contentView else { return false }
            let scrollViews = self.scrollViews(in: root)
            return scrollViews.count == 2
                && scrollViews.allSatisfy(self.isStyled)
        }
        XCTAssertTrue(styled)
    }

    private func isStyled(_ scrollView: NSScrollView) -> Bool {
        guard let scroller = scrollView.verticalScroller else { return false }
        return scroller.controlSize == .mini
            && abs(scroller.alphaValue - 0.45) < 0.001
    }

    private func scrollViews(in root: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scrollView = view as? NSScrollView {
                found.append(scrollView)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }
}

@MainActor
private final class DynamicScrollState: ObservableObject {
    @Published var showsScrollView = false
}

private struct DynamicScrollRoot: View {
    let state: DynamicScrollState

    var body: some View {
        VStack {
            ScrollView {
                VStack {
                    ForEach(0..<10, id: \.self) { row in
                        Text("Initial \(row)")
                    }
                }
            }
            .frame(height: 40)
            DynamicScrollChild(state: state)
        }
        .installSubduedScrollbars()
    }
}

private struct DynamicScrollChild: View {
    @ObservedObject var state: DynamicScrollState

    @ViewBuilder
    var body: some View {
        if state.showsScrollView {
            SubduedScrollView {
                VStack {
                    ForEach(0..<40, id: \.self) { row in
                        Text("Row \(row)")
                    }
                }
            }
        } else {
            Color.clear
        }
    }
}
