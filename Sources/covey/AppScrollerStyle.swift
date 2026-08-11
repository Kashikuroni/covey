import AppKit
import SwiftUI

@MainActor
enum AppScrollerStyle {
    static let opacity: CGFloat = 0.45

    static func apply(to scroller: NSScroller) {
        scroller.controlSize = .mini
        scroller.alphaValue = opacity
    }

    static func apply(to scrollView: NSScrollView) {
        if let vertical = scrollView.verticalScroller { apply(to: vertical) }
        if let horizontal = scrollView.horizontalScroller { apply(to: horizontal) }
    }

    static func applyRecursively(in view: NSView) {
        if let scrollView = view as? NSScrollView { apply(to: scrollView) }
        if let scroller = view as? NSScroller { apply(to: scroller) }
        for child in view.subviews { applyRecursively(in: child) }
    }
}

private struct AppScrollbarInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        InstallerView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? InstallerView)?.install()
    }

    private final class InstallerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            install()
        }

        func install() {
            DispatchQueue.main.async { [weak self] in
                guard let root = self?.window?.contentView else { return }
                AppScrollerStyle.applyRecursively(in: root)
            }
        }
    }
}

extension View {
    func installSubduedScrollbars() -> some View {
        background(AppScrollbarInstaller().frame(width: 0, height: 0))
    }
}

struct SubduedScrollView<Content: View>: View {
    private let axes: Axis.Set
    private let showsIndicators: Bool
    private let content: Content

    init(
        _ axes: Axis.Set = .vertical,
        showsIndicators: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.axes = axes
        self.showsIndicators = showsIndicators
        self.content = content()
    }

    var body: some View {
        ScrollView(axes, showsIndicators: showsIndicators) {
            content
        }
        .installSubduedScrollbars()
    }
}
