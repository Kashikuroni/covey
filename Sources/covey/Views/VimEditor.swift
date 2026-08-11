import SwiftUI
import AppKit
import CoveyKit

/// Reusable vim-lite markdown editor: NORMAL/INSERT/VISUAL over the raw
/// text (NSTextView with a line-number ruler) and a PREVIEW mode rendering
/// obsidian-style markdown with scroll-only navigation.
struct VimEditor: View {
    @Binding var text: String
    @Binding var modeBadge: String
    var tk: Tokens
    var startInPreview = false
    /// Bump to hand the editor the keyboard (zone entry).
    var focusTick = 0
    var onSwitchField: (Bool) -> Void

    @State private var box: VimBox

    init(text: Binding<String>, modeBadge: Binding<String>, tk: Tokens,
         startInPreview: Bool = false, focusTick: Int = 0,
         onSwitchField: @escaping (Bool) -> Void) {
        _text = text
        _modeBadge = modeBadge
        self.tk = tk
        self.startInPreview = startInPreview
        self.focusTick = focusTick
        self.onSwitchField = onSwitchField
        _box = State(initialValue: VimBox(startInPreview: startInPreview))
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if box.isPreview {
                    VimPreview(box: box, text: text, tk: tk, focusTick: focusTick)
                } else {
                    VimTextRepresentable(box: box, text: $text, focusTick: focusTick,
                                         onSwitchField: onSwitchField)
                }
            }
            // Hints only while the editor owns the keyboard — otherwise
            // they are just noise.
            if box.focused {
                editorFooter
            }
        }
        .background(tk.surf2, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder(box.focused ? tk.accent.opacity(0.7) : tk.bd2))
        // The badge belongs to the FOCUSED editor only — release it on blur
        // so a background pane's PREVIEW never haunts the footer.
        .onChange(of: box.badge) { _, badge in
            if box.focused { modeBadge = badge }
        }
        .onChange(of: box.focused) { _, focused in
            modeBadge = focused ? box.badge : ""
        }
        .onAppear {
            box.engine.syncFromView(text: text, cursor: 0)
        }
        .onChange(of: text) { _, t in
            // The preview has no NSTextView to sync through.
            if box.isPreview {
                box.engine.syncFromView(text: t, cursor: box.engine.cursor)
            }
        }
    }

    /// The editor's own footer: mode-scoped key hints + the mode badge —
    /// the app footer only carries app-level hints.
    private var editorFooter: some View {
        HStack(spacing: 8) {
            ForEach(modeHints, id: \.0) { key, label in
                KbdBadge(key: key, label: label, tk: tk)
            }
            Spacer()
            Text(box.badge)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(badgeColor(box.badge))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    private var modeHints: [(String, String)] {
        switch box.badge {
        case "PREVIEW":
            return [("enter", "normal")]
        case "INSERT":
            return [("esc", "normal")]
        case "VISUAL", "V-LINE":
            return [("y / d / c", "yank · del · change"), ("esc", "normal")]
        default:   // NORMAL
            return [("i", "insert"), ("v / V", "visual · line"),
                    ("u / ⌃r", "undo · redo"), ("gp", "preview")]
        }
    }

    private func badgeColor(_ badge: String) -> Color {
        switch badge {
        case "INSERT": return tk.warn
        case "VISUAL", "V-LINE": return tk.accent
        case "PREVIEW": return tk.ok
        default: return tk.t4
        }
    }
}

/// Shared mutable home of the engine: the NSView layer and the SwiftUI
/// preview both talk to the same state.
@Observable
final class VimBox {
    var engine: VimEngine
    var badge = "INSERT"
    var focused = false
    var scrollCenterTick = 0
    /// Keyboard handover across the preview<->text remount: the outgoing
    /// side raises it, the incoming side consumes it and grabs focus.
    var wantsFocus = false

    init(startInPreview: Bool = false) {
        engine = VimEngine(startInPreview: startInPreview)
        refreshBadge()
    }

    var isPreview: Bool { engine.mode == .preview }

    func refreshBadge() {
        switch engine.mode {
        case .normal: badge = "NORMAL"
        case .insert: badge = "INSERT"
        case .visual: badge = "VISUAL"
        case .visualLine: badge = "V-LINE"
        case .preview: badge = "PREVIEW"
        }
    }

    /// Feed one input; applies clipboard/scroll effects. Returns the
    /// switch-field direction if the engine asked to leave the editor.
    func handle(_ input: VimInput) -> Bool? {
        let effect = engine.handle(input, pasteboard: {
            NSPasteboard.general.string(forType: .string)
        })
        refreshBadge()
        switch effect {
        case .setPasteboard(let s):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        case .scrollCenter:
            scrollCenterTick += 1
        case .switchField(let forward):
            return forward
        case .none: break
        }
        return nil
    }
}

// MARK: - text modes (normal/insert/visual)

private struct VimTextRepresentable: NSViewRepresentable {
    let box: VimBox
    @Binding var text: String
    var focusTick = 0
    var onSwitchField: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(box: box, text: $text, onSwitchField: onSwitchField)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let view = VimNSTextView()
        view.box = box
        view.coordinator = context.coordinator
        view.delegate = context.coordinator
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.drawsBackground = false
        view.allowsUndo = true
        view.isRichText = false
        view.string = text
        // Keep the engine's cursor when returning from the preview.
        if box.engine.text != text {
            box.engine.syncFromView(text: text, cursor: 0)
        }
        view.setSelectedRange(NSRange(
            location: min(box.engine.cursor, (text as NSString).length), length: 0))
        box.refreshBadge()

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        AppScrollerStyle.apply(to: scroll)
        scroll.drawsBackground = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true

        let ruler = LineNumberRuler(scrollView: scroll, textView: view)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        // macOS 14+: views no longer clip by default — without this the
        // ruler bleeds across the whole window.
        scroll.clipsToBounds = true
        ruler.clipsToBounds = true
        if box.wantsFocus {
            // Arriving from the preview (Esc / i): take the keyboard.
            box.wantsFocus = false
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                view.window?.makeFirstResponder(view)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? VimNSTextView else { return }
        if view.string != text, box.engine.mode == .insert {
            // External draft change (project switch): reload.
            view.string = text
            box.engine.syncFromView(text: text, cursor: 0)
        }
        if context.coordinator.lastFocusTick != focusTick {
            context.coordinator.lastFocusTick = focusTick
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                view.window?.makeFirstResponder(view)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let box: VimBox
        var text: Binding<String>
        var lastFocusTick = 0
        let onSwitchField: (Bool) -> Void
        init(box: VimBox, text: Binding<String>, onSwitchField: @escaping (Bool) -> Void) {
            self.box = box; self.text = text; self.onSwitchField = onSwitchField
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
            box.engine.syncFromView(text: view.string,
                                    cursor: view.selectedRange().location)
        }

        /// Apply engine state back into the view after a normal/visual key.
        func sync(into view: NSTextView) {
            defer {
                // Mode may have flipped (i/Esc): redraw the caret shape.
                view.updateInsertionPointStateAndRestartTimer(true)
                view.needsDisplay = true
            }
            if view.string != box.engine.text {
                view.string = box.engine.text
                text.wrappedValue = box.engine.text
            }
            let length = (view.string as NSString).length
            let c = min(box.engine.cursor, length)
            if case .visual(let anchor) = box.engine.mode {
                let lo = min(anchor, c)
                let hi = min(max(anchor, c) + 1, length)
                view.setSelectedRange(NSRange(location: lo, length: hi - lo))
            } else if case .visualLine(let anchor) = box.engine.mode {
                // Highlight whole lines from the anchor's line to the cursor's.
                let ns = view.string as NSString
                let a = min(min(anchor, c), length)
                let b = min(max(anchor, c), length)
                let lineA = ns.lineRange(for: NSRange(location: a, length: 0))
                let lineB = ns.lineRange(for: NSRange(location: b, length: 0))
                let start = lineA.location
                let end = lineB.location + lineB.length
                view.setSelectedRange(NSRange(location: start, length: max(0, end - start)))
            } else {
                view.setSelectedRange(NSRange(location: c, length: 0))
            }
            view.scrollRangeToVisible(view.selectedRange())
        }
    }
}

/// NSTextView that gives non-insert keys to the engine.
private final class VimNSTextView: NSTextView {
    weak var box: VimBox?
    var coordinator: VimTextRepresentable.Coordinator?

    override func becomeFirstResponder() -> Bool {
        box?.focused = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        box?.focused = false
        return super.resignFirstResponder()
    }

    /// NORMAL wears a block caret (vim), INSERT the regular bar.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard let box, box.engine.mode != .insert else {
            return super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
        }
        guard flag else {
            setNeedsDisplay(blockCaretRect(from: rect))
            return
        }
        color.withAlphaComponent(0.45).setFill()
        blockCaretRect(from: rect).fill()
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        // The block caret is wider than the bar rect AppKit invalidates.
        super.setNeedsDisplay(blockCaretRect(from: rect), avoidAdditionalLayout: flag)
    }

    private func blockCaretRect(from rect: NSRect) -> NSRect {
        var r = rect
        // Widen a thin caret rect to a block; never SHRINK a wider invalidation.
        // Clamping every setNeedsDisplay rect to one char left most of a pasted
        // or freshly-typed run unpainted — the "invisible/white text" bug.
        let m = ("m" as NSString).size(withAttributes: [.font: font as Any]).width
        r.size.width = max(r.size.width, m)
        return r
    }

    override func keyDown(with event: NSEvent) {
        guard let box, let coordinator else { return super.keyDown(with: event) }
        // Vim redo (⌃R) — caught before the general ⌘/⌃ passthrough. `u` (undo)
        // is a plain NORMAL key and flows through the engine path below.
        // Match by keyCode: ⌃R's charactersIgnoringModifiers is the DC2 control
        // char, not "r", so a string compare would silently miss.
        if box.engine.mode == .normal,
           event.modifierFlags.contains(.control),
           event.keyCode == 15 {   // kVK_ANSI_R
            _ = box.handle(.redo)
            coordinator.sync(into: self)
            return
        }
        // ⌘/⌃-chords belong to the app (zone cycling, form shortcuts).
        if !event.modifierFlags.intersection([.command, .control]).isEmpty {
            return super.keyDown(with: event)
        }
        let input = vimInput(from: event)
        if box.engine.mode == .insert {
            if input == .escape {
                _ = box.handle(.escape)
                coordinator.sync(into: self)
                return
            }
            return super.keyDown(with: event)   // native typing
        }
        // Bare j/k move by DISPLAY line (wrap-aware) in normal / char-visual so
        // the rows of a soft-wrapped logical line are reachable. Operator/count
        // forms (dj, 3j) and V stay logical through the engine below.
        if displayLineNav(input, mode: box.engine.mode),
           box.engine.pending == nil, box.engine.count == nil, !box.engine.pendingG {
            moveByDisplayLine(down: input == .char("j"))
            return
        }
        // Before a normal/visual key make sure the engine sees the caret —
        // EXCEPT in V-LINE. There the selection spans whole lines and its
        // `.location` is the block TOP; adopting it would collapse the moving
        // end onto the top row, so j/k stall the moment a line wraps (the
        // wrapped continuation is one logical line the engine already spans).
        // In V-LINE the engine's own cursor is the moving end — leave it.
        switch box.engine.mode {
        case .visualLine: break
        default: box.engine.syncFromView(text: string, cursor: selectedRange().location)
        }
        if let forward = box.handle(input) {
            coordinator.onSwitchField(forward)
            return
        }
        coordinator.sync(into: self)
        if box.isPreview {
            // gp: the SwiftUI preview replaces this view — hand it the keys.
            box.wantsFocus = true
            window?.makeFirstResponder(nil)
        }
    }

    private func vimInput(from event: NSEvent) -> VimInput {
        switch event.keyCode {
        case 53: return .escape
        case 48: return event.modifierFlags.contains(.shift) ? .shiftTab : .tab
        default:
            let raw = event.charactersIgnoringModifiers?.first ?? " "
            return .char(latinize(raw))
        }
    }

    /// Bare j/k in a mode where display-line motion applies (normal or
    /// char-wise visual — never V-LINE, preview or insert).
    private func displayLineNav(_ input: VimInput, mode: VimEngine.Mode) -> Bool {
        guard input == .char("j") || input == .char("k") else { return false }
        switch mode {
        case .normal, .visual: return true
        default: return false
        }
    }

    /// Move the caret one wrapped display row via AppKit (which keeps the
    /// ideal column), then feed the resulting offset back to the engine.
    private func moveByDisplayLine(down: Bool) {
        guard let box, let coordinator else { return }
        let length = (string as NSString).length
        if case .visual = box.engine.mode {
            // Keep the engine's visual anchor; move only the caret end.
            setSelectedRange(NSRange(location: min(box.engine.cursor, length), length: 0))
        } else {
            // Normal: adopt the view caret (honors a mouse click) without
            // re-setting it, so AppKit keeps the ideal column across repeats.
            box.engine.syncFromView(text: string, cursor: selectedRange().location)
        }
        if down { moveDown(nil) } else { moveUp(nil) }
        box.engine.syncFromView(text: string, cursor: selectedRange().location)
        if case .visual = box.engine.mode {
            coordinator.sync(into: self)                     // re-render the range
        } else {
            updateInsertionPointStateAndRestartTimer(true)   // block caret, keep column
            needsDisplay = true
        }
        scrollRangeToVisible(selectedRange())
    }
}

/// Classic line-number gutter for an NSTextView.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 26
        NotificationCenter.default.addObserver(
            self, selector: #selector(needsRedraw),
            name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(needsRedraw),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
    }

    required init(coder: NSCoder) { fatalError("unused") }

    @objc private func needsRedraw() { needsDisplay = true }

    // The stock ruler chrome paints a separator that (unclipped since
    // macOS 14) runs the whole window height — draw only our numbers.
    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager,
              let container = tv.textContainer else { return }
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: container)
        let content = tv.string as NSString
        guard content.length > 0 else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            ("1" as NSString).draw(at: NSPoint(x: ruleThickness - 10, y: 0),
                                   withAttributes: attrs)
            return
        }
        var line = content.substring(to: lm.characterIndexForGlyph(at: glyphs.location))
            .components(separatedBy: "\n").count
        var glyph = glyphs.location
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        while glyph < NSMaxRange(glyphs) {
            var effective = NSRange()
            let lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective)
            let charRange = lm.characterRange(forGlyphRange: effective, actualGlyphRange: nil)
            let isLineStart = charRange.location == 0
                || content.character(at: charRange.location - 1) == 0x0A
            if isLineStart {
                let y = lineRect.minY - visible.minY + tv.textContainerInset.height
                let label = "\(line)" as NSString
                let size = label.size(withAttributes: attrs)
                label.draw(at: NSPoint(x: ruleThickness - size.width - 4, y: y),
                           withAttributes: attrs)
                line += 1
            }
            glyph = NSMaxRange(effective)
        }
    }
}

// MARK: - preview

/// Obsidian-style read view: line numbers + parseNote line rendering;
/// scroll follows the engine's cursor line.
private struct VimPreview: View {
    let box: VimBox
    let text: String
    let tk: Tokens
    var focusTick = 0
    @FocusState private var focused: Bool

    var body: some View {
        let lines = parseNote(text)
        ScrollViewReader { proxy in
            SubduedScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(idx + 1)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(tk.t4)
                                .frame(width: 18, alignment: .trailing)
                            MarkdownLineView(line: line, tk: tk)
                            Spacer(minLength: 0)
                        }
                        .padding(.trailing, 4)
                        .id(idx)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: box.engine.cursor) { _, _ in
                proxy.scrollTo(box.engine.lineOfCursor())
            }
            .onChange(of: box.scrollCenterTick) { _, _ in
                proxy.scrollTo(box.engine.lineOfCursor(), anchor: .center)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // Grab the keyboard only when the editor already owned it (mode
        // switch) — never on a cold mount (app launch would steal focus).
        .onAppear {
            if box.wantsFocus || box.focused {
                box.wantsFocus = false
                focused = true
            }
        }
        .onChange(of: focusTick) { _, _ in focused = true }
        .onChange(of: focused) { _, f in box.focused = f }
        .onTapGesture { focused = true }
        .onKeyPress(phases: .down) { press in
            let input: VimInput = press.key == .escape ? .escape
                : .char(latinize(press.characters.first ?? " "))
            _ = box.handle(input)
            if !box.isPreview {
                // Leaving the preview: the NSTextView takes over the keys.
                box.wantsFocus = true
                focused = false
            }
            return .handled
        }
    }

}
