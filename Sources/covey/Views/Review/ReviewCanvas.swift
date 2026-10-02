import SwiftUI
import AppKit
import CoveyGit

struct ReviewCanvas: View {
    @Bindable var model: ReviewModel
    let tk: Tokens
    @State private var dragOrigin: CanvasTransform?
    @State private var pinchOrigin: CanvasTransform?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                CanvasGrid(transform: model.canvas, tk: tk)
                world
                    .scaleEffect(model.canvas.zoom, anchor: .topLeading)
                    .offset(x: model.canvas.pan.width, y: model.canvas.pan.height)
                title
                if model.phase == .ready && model.files.isEmpty {
                    Text("No changes in this comparison.")
                        .font(.system(size: 13))
                        .foregroundStyle(tk.t3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Spacer()
                    legend
                    CanvasToolbar(model: model, tk: tk)
                }
                .padding(.leading, 24)
                .padding(.bottom, 20)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            // Simultaneous: a click on a card or a toolbar button also ends
            // text editing, and the card/button still gets its own tap.
            .simultaneousGesture(TapGesture().onEnded { resignReviewTextFocus() })
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { value in
                    if dragOrigin == nil { dragOrigin = model.canvas }
                    model.canvas = dragOrigin!.panned(by: value.translation)
                }
                .onEnded { _ in dragOrigin = nil })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    if pinchOrigin == nil { pinchOrigin = model.canvas }
                    model.canvas = pinchOrigin!.zoomed(by: value.magnification, around: value.startLocation)
                }
                .onEnded { _ in pinchOrigin = nil })
            .background {
                CanvasScrollMonitor(enabled: model.sendDraft == nil && !model.keysOverlayOpen) { delta, zoom, location in
                    if zoom {
                        model.canvas = model.canvas.zoomed(by: exp(delta.height * 0.01), around: location)
                    } else {
                        model.canvas = model.canvas.panned(by: delta)
                    }
                }
            }
            .onAppear { model.setCanvasViewport(geo.size) }
            .onChange(of: geo.size) { _, size in model.setCanvasViewport(size) }
        }
        .background(tk.bg)
    }

    private var world: some View {
        let layout = model.graphLayout
        let bounds = layout.bounds ?? .zero
        return ZStack(alignment: .topLeading) {
            ForEach(Array(layout.captions.enumerated()), id: \.offset) { _, caption in
                Text(caption.text)
                    .font(ReviewFont.caption(11))
                    .foregroundStyle(tk.t4)
                    .lineLimit(1)
                    .offset(x: caption.origin.x, y: caption.origin.y)
            }
            ForEach(layout.cards.filter { $0.kind == .changed }, id: \.path) { card in
                if let file = model.file(card.path) {
                    ReviewFileCard(file: file, review: model.review(for: file.path),
                                   openIssues: model.openIssueCount(file.path),
                                   comments: model.commentCount(file.path),
                                   selected: model.selectedPath == file.path,
                                   dimmed: !model.matchesFilter(file), tk: tk)
                        .frame(width: card.rect.width, height: card.rect.height)
                        .offset(x: card.rect.minX, y: card.rect.minY)
                        .onTapGesture {
                            resignReviewTextFocus()
                            Task { await model.select(file.path) }
                        }
                }
            }
        }
        .frame(width: bounds.maxX + 1, height: bounds.maxY + 1, alignment: .topLeading)
    }

    private var title: some View {
        let added = model.files.reduce(0) { $0 + ($1.added ?? 0) }
        let removed = model.files.reduce(0) { $0 + ($1.removed ?? 0) }
        let comparison = model.record.comparison
        return VStack(alignment: .leading, spacing: 8) {
            Text("REVIEW · \(comparison.base.isEmpty ? "no comparison" : comparison.label)")
                .font(ReviewFont.caption())
                .foregroundStyle(tk.t3)
            Text(model.branchLabel)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(tk.t1)
                .lineLimit(1)
            Text("\(model.files.count) files · +\(added) −\(removed)")
                .font(.system(size: 13))
                .foregroundStyle(tk.t2)
        }
        .padding(.leading, 28)
        .padding(.top, 24)
        .allowsHitTesting(false)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(FileStatus.allCases, id: \.self) { status in
                Text("■ \(status.label)").foregroundStyle(status.color(tk))
            }
        }
        .font(ReviewFont.caption(10))
        .allowsHitTesting(false)
    }
}

struct ReviewFileCard: View {
    let file: ChangedFile
    let review: FileReview
    let openIssues: Int
    let comments: Int
    let selected: Bool
    let dimmed: Bool
    let tk: Tokens

    var body: some View {
        let glyph = ReviewGlyph.of(review, hasOpenIssues: openIssues > 0)
        let dir = (file.path as NSString).deletingLastPathComponent
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                if !dir.isEmpty { Text(dir + "/").foregroundStyle(tk.t3) }
                Text((file.path as NSString).lastPathComponent)
                    .foregroundStyle(tk.t1)
                    .strikethrough(file.status == .deleted)
                Spacer(minLength: 6)
                Text(glyph.symbol).foregroundStyle(glyph.color(tk))
            }
            .font(ReviewFont.mono(12))
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, 12)
            .frame(height: 34)
            Rectangle().fill(tk.bd2).frame(height: 1)
            HStack(spacing: 10) {
                Text(file.status.label).font(ReviewFont.caption(10)).foregroundStyle(file.status.color(tk))
                Text(file.added.map { "+\($0)" } ?? (file.isBinary ? "bin" : "?"))
                    .font(ReviewFont.mono(11)).foregroundStyle(tk.diffAdd)
                Text(file.removed.map { "−\($0)" } ?? "")
                    .font(ReviewFont.mono(11)).foregroundStyle(tk.diffDel)
                ratioBar
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            Rectangle().fill(tk.bd2).frame(height: 1)
            HStack(spacing: 12) {
                Text(openIssues == 0 ? "No issues" : "\(openIssues) open issue\(openIssues == 1 ? "" : "s")")
                    .foregroundStyle(openIssues == 0 ? tk.t4 : tk.err)
                if comments > 0 {
                    Text("\(comments) comment\(comments == 1 ? "" : "s")").foregroundStyle(tk.t3)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .frame(height: 31)
        }
        .background(tk.card)
        .overlay(RoundedRectangle(cornerRadius: Tokens.rSm)
            .stroke(selected ? tk.accent : tk.bd3, lineWidth: selected ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.rSm))
        .shadow(color: tk.shadowColor, radius: selected ? 10 : 3, y: 2)
        .opacity(dimmed ? 0.35 : 1)
    }

    private var ratioBar: some View {
        GeometryReader { geo in
            let added = CGFloat(file.added ?? 0)
            let removed = CGFloat(file.removed ?? 0)
            let total = max(added + removed, 1)
            HStack(spacing: 0) {
                tk.diffAdd.frame(width: geo.size.width * added / total)
                tk.diffDel.frame(width: geo.size.width * removed / total)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 3)
        .background(tk.bd2)
    }
}

struct CanvasGrid: View {
    let transform: CanvasTransform
    let tk: Tokens

    var body: some View {
        Canvas { context, size in
            let step = 24 * transform.zoom
            guard step >= 6 else { return }
            var path = Path()
            var x = transform.pan.width.truncatingRemainder(dividingBy: step)
            if x < 0 { x += step }
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y = transform.pan.height.truncatingRemainder(dividingBy: step)
            if y < 0 { y += step }
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(path, with: .color(tk.bd2.opacity(0.5)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

struct CanvasToolbar: View {
    @Bindable var model: ReviewModel
    let tk: Tokens

    var body: some View {
        HStack(spacing: 0) {
            icon("sidebar.left", help: "Toggle file tree") { model.sidebarVisible.toggle() }
            divider
            icon("minus", help: "Zoom out") { model.zoomCanvas(by: 1 / 1.2) }
            Text("\(Int((model.canvas.zoom * 100).rounded()))%")
                .font(ReviewFont.mono(11))
                .foregroundStyle(tk.t2)
                .frame(width: 46)
            icon("plus", help: "Zoom in") { model.zoomCanvas(by: 1.2) }
            divider
            label("Fit", hint: "F") { model.fitCanvas() }
            divider
            label("Focus", hint: "3") { model.focusCard() }
            divider
            icon("questionmark", help: "Keyboard") { model.keysOverlayOpen = true }
        }
        .frame(height: 32)
        .background(tk.surf2)
        .overlay(RoundedRectangle(cornerRadius: Tokens.rSm).stroke(tk.bd3))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.rSm))
    }

    private var divider: some View { Rectangle().fill(tk.bd3).frame(width: 1, height: 32) }

    private func icon(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12)).foregroundStyle(tk.t1).frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func label(_ title: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12)).foregroundStyle(tk.t1)
                Text(hint).font(ReviewFont.mono(10)).foregroundStyle(tk.t3)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Wheel/trackpad scrolling over the canvas: pan, or zoom with ⌘. A local
/// monitor because SwiftUI has no scroll-wheel gesture on macOS; the view
/// itself never takes clicks.
struct CanvasScrollMonitor: NSViewRepresentable {
    var enabled: Bool
    let onScroll: (CGSize, Bool, CGPoint) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.enabled = enabled
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.enabled = enabled
        view.onScroll = onScroll
    }

    final class MonitorView: NSView {
        var enabled = true
        var onScroll: ((CGSize, Bool, CGPoint) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.enabled, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                self.onScroll?(CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale),
                               event.modifierFlags.contains(.command), point)
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
