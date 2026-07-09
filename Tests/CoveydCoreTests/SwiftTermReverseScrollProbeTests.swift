import XCTest
import SwiftTerm

/// Diagnostic characterization probe (NOT a product test) for the long-standing
/// "slow scroll-up in claude renders a frozen center" bug. Drives SwiftTerm's
/// headless `Terminal` emulator directly — no view, no claude, no trackpad — and
/// records the damage range (`getUpdateRange()`) that each candidate scroll-up
/// primitive marks. Row-only, 0-indexed; full screen is rows 0…24.
///
/// Why: `updateDisplay` (AppleTerminalView.swift:1572) repaints ONLY the rows in
/// `getUpdateRange()`. A primitive that shifts the whole screen but marks fewer
/// rows than it moved leaves the unmarked rows STALE → the "frozen center". The
/// forward direction (LF/index → `scroll()`) always marks the full region in the
/// alt buffer, which is why scrolling DOWN never freezes. This probe shows which
/// UP primitives under-mark, so that once the real claude byte stream is captured
/// (see scratchpad/instrumentation.md) we can immediately tell if it hits one.
///
/// FINDING baked in as assertions below:
///  • forward LF at bottom → full region (down is safe).
///  • RI at scrollTop (no margin) → full region (safe).
///  • RI with cursor OFF scrollTop → marks ONLY the cursor row and does NOT shift
///    content: an under-paint. This is the SwiftTerm-side of hypothesis H1; it is
///    real and reachable, but requires the cursor to be off scrollTop when RI
///    arrives — an unproven property of claude's output.
final class SwiftTermReverseScrollProbeTests: XCTestCase {
    private final class NoopDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private func esc(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// 80x25 alternate-buffer terminal, every visible row carrying text.
    private func makeAltTerminal() -> Terminal {
        let t = Terminal(delegate: NoopDelegate(), options: .default)
        t.feed(byteArray: esc("\u{1b}[?1049h"))
        for r in 1...25 { t.feed(byteArray: esc("\u{1b}[\(r);1Hrow\(r)")) }
        return t
    }

    /// Feed `seq` onto a freshly filled alt terminal (after clearing damage) and
    /// return the marked range and how many rows it covers out of 25.
    private func damage(after seq: String, prep: String = "") -> (range: (startY: Int, endY: Int)?, rows: Int) {
        let t = makeAltTerminal()
        if !prep.isEmpty { t.feed(byteArray: esc(prep)) }
        t.clearUpdateRange()
        t.feed(byteArray: esc(seq))
        let r = t.getUpdateRange()
        return (r, r.map { $0.endY - $0.startY + 1 } ?? 0)
    }

    /// Prints a table; the hard asserts are the controls + the documented finding.
    func testCharacterizeScrollUpDamageMarking() {
        let cases: [(name: String, prep: String, seq: String)] = [
            ("DOWN: LF at bottom (index→scroll)",        "\u{1b}[25;1H", "\n"),
            ("UP: RI at top, no margin",                 "\u{1b}[1;1H",  "\u{1b}M"),
            ("UP: RI with cursor mid-screen (off top)",  "\u{1b}[12;1H", "\u{1b}M"),
            ("UP: RI under top-margin region 2..25",     "\u{1b}[2;25r\u{1b}[2;1H", "\u{1b}M"),
            ("UP: IL insert-line at top",                "\u{1b}[1;1H",  "\u{1b}[L"),
            ("UP: SD scroll-down region",                "\u{1b}[1;1H",  "\u{1b}[T"),
        ]
        print("=== scroll-up damage characterization (rows 0..24) ===")
        for c in cases {
            let d = damage(after: c.seq, prep: c.prep)
            print(String(format: "%-42@  range=%@  rows=%d/25",
                         c.name as NSString,
                         (d.range.map { "(\($0.startY)…\($0.endY))" } ?? "nil") as NSString,
                         d.rows))
        }

        // Controls that must hold for the whole diagnosis to make sense:
        XCTAssertEqual(damage(after: "\n", prep: "\u{1b}[25;1H").rows, 25,
                       "forward scroll (down) must mark the FULL region")
        XCTAssertEqual(damage(after: "\u{1b}M", prep: "\u{1b}[1;1H").rows, 25,
                       "RI at scrollTop must mark the FULL region")

        // Documented under-paint: RI off scrollTop marks < full region.
        let offTop = damage(after: "\u{1b}M", prep: "\u{1b}[12;1H")
        XCTAssertLessThan(offTop.rows, 25,
                          "RI off scrollTop under-marks (this is the SwiftTerm-side freeze mechanism)")
    }

    // MARK: - claude's REAL scroll mechanism (captured 2026-07-09 PTY dump)
    //
    // The byte capture proved claude does NOT use reverse-index. Each scroll frame
    // is: `ESC[?2026h` (begin synchronized output) · `ESC[2;43r` (DECSTBM region
    // rows 2..43) · `ESC[<n>S`/`ESC[<n>T` (SU/SD by n; n=1 slow, n=9 flick) · `ESC[r`
    // (reset region) · redraw a few exposed lines · `ESC[?2026l` (end sync).
    // These tests feed those EXACT sequences into a claude-shaped terminal
    // (100x48, alt buffer, region 2..43) to check the emulation + damage layer.

    private func makeClaudeShaped() -> Terminal {
        let t = Terminal(delegate: NoopDelegate(), options: TerminalOptions(cols: 100, rows: 48))
        t.feed(byteArray: esc("\u{1b}[?1049h"))
        for r in 1...48 { t.feed(byteArray: esc("\u{1b}[\(r);1Hrow\(r)")) }
        return t
    }

    /// A minimal real slow-up frame (n=1) and a flick-up frame (n=9), 2026-wrapped.
    private func frame(su n: Int) -> String {
        "\u{1b}[?2026h\u{1b}[?25l\u{1b}[H\u{1b}[2;43r\u{1b}[\(n)S\u{1b}[r"
        + "\u{1b}[H\r\u{1b}[41B\u{1b}[K\r\u{1b}[1Bexposed\u{1b}[48;1H\u{1b}[46;3H\u{1b}[?25h\u{1b}[?2026l"
    }

    /// Whole frame in ONE feed → after end-sync the whole screen must be marked
    /// dirty (endSynchronizedOutput calls refresh(0, rows-1)). Both n=1 and n=9.
    func testFullFrameMarksFullScreen() {
        for n in [1, 9] {
            let t = makeClaudeShaped()
            t.clearUpdateRange()
            t.feed(byteArray: esc(frame(su: n)))
            let r = t.getUpdateRange()
            XCTAssertNotNil(r, "SU \(n): a complete 2026 frame must leave damage")
            XCTAssertEqual(r?.startY, 0, "SU \(n): end-sync should refresh from row 0")
            XCTAssertEqual(r?.endY, 47, "SU \(n): end-sync should refresh to the last row")
        }
    }

    /// THE covey scenario: the daemon delivers PTY output in ~1024-byte chunks, so
    /// a 2026 frame is split across feed() calls, and the 60fps throttle can fire a
    /// render (getUpdateRange → clearUpdateRange) MID-sync. Does the frame still heal?
    /// Split right after the SU, before end-sync, simulate a render, then feed the
    /// rest. The final damage MUST be the full screen (end-sync refresh) or the
    /// scrolled center is never repainted → frozen.
    func testSplitFrameMidSyncStillHeals() {
        for n in [1, 9] {
            let t = makeClaudeShaped()
            let full = frame(su: n)
            // Split just after `ESC[r` (region reset), while sync is still active.
            let cut = full.range(of: "\u{1b}[r")!.upperBound
            let chunkA = String(full[full.startIndex..<cut])
            let chunkB = String(full[cut...])

            t.clearUpdateRange()
            t.feed(byteArray: esc(chunkA))           // sync active, SU applied
            _ = t.getUpdateRange()                    // simulate throttled updateDisplay…
            t.clearUpdateRange()                      // …which clears the range after painting
            t.feed(byteArray: esc(chunkB))            // rest incl. ESC[?2026l (end sync)

            let r = t.getUpdateRange()
            XCTAssertNotNil(r, "SU \(n) split: end-sync must re-mark damage after a mid-sync render")
            XCTAssertEqual(r?.startY, 0, "SU \(n) split: heal must cover from row 0 (else frozen center)")
            XCTAssertEqual(r?.endY, 47, "SU \(n) split: heal must cover to the last row")
        }
    }

    // Does SU actually SHIFT the alt-buffer CONTENT (not just mark damage)? The
    // runtime draw log proved draw() repaints the FULL screen every frame, yet the
    // center freezes — which is only possible if the buffer the draw reads is NOT
    // scrolled. This inspects cell content after claude's real region+SU sequence.
    private func rowText(_ t: Terminal, _ row: Int, _ n: Int = 4) -> String {
        var s = ""
        for c in 0..<n { s.append(t.getCharacter(col: c, row: row) ?? "·") }
        return s
    }

    private func makeMarkedAlt() -> Terminal {
        let t = Terminal(delegate: NoopDelegate(), options: TerminalOptions(cols: 100, rows: 48))
        t.feed(byteArray: esc("\u{1b}[?1049h"))
        for r in 0..<48 {                              // row r carries marker "L##_"
            t.feed(byteArray: esc("\u{1b}[\(r + 1);1HL\(String(format: "%02d", r))_"))
        }
        return t
    }

    func testScrollUpShiftsAltBufferContent() {
        for n in [1, 9] {
            let t = makeMarkedAlt()
            XCTAssertEqual(rowText(t, 20), "L20_", "SU \(n): precondition — center is its own marker")
            // claude's real frame core: DECSTBM region rows 2..43, SU n, reset.
            t.feed(byteArray: esc("\u{1b}[2;43r\u{1b}[\(n)S\u{1b}[r"))
            let got = rowText(t, 20)
            let want = "L\(String(format: "%02d", 20 + n))_"   // center shows old row 20+n
            print("SU \(n): row19=\(rowText(t,19)) row20=\(got) row21=\(rowText(t,21)) want row20=\(want)")
            XCTAssertEqual(got, want,
                "SU \(n) must SHIFT the center of the alt buffer; if it stays L20_ the buffer never scrolled (frozen center despite full redraw)")
        }
    }

    // THE ROOT CAUSE. covey builds the view at `frame: .zero`, so the terminal is
    // born at ~0 columns → Buffer sets marginRight = cols-1 = -1. Buffer.resize only
    // ever SHRINKS marginRight (Buffer.swift:410), never grows it, so after the pane
    // lays out to its real width the margins stay collapsed. `cmdScrollDown` (CSI T /
    // SD — the op claude emits to scroll the chat UP toward older messages) then uses
    // `columnCount = marginRight - marginLeft + 1` UNCONDITIONALLY, i.e. ~1 column,
    // so a scroll copies only the leftmost column → the center freezes and a 1-char
    // strip crawls on the left. (cmdScrollUp's non-margin path splices whole lines, so
    // scrolling the other way works — the up/down asymmetry.)
    func testScrollDownAfterGrowResizeShiftsFullWidth() {
        let t = Terminal(delegate: NoopDelegate(), options: TerminalOptions(cols: 1, rows: 48))
        t.resize(cols: 100, rows: 48)                  // mimic covey: born at ~0, grown later
        t.feed(byteArray: esc("\u{1b}[?1049h"))
        for r in 0..<48 { t.feed(byteArray: esc("\u{1b}[\(r + 1);1HL\(String(format: "%02d", r))_")) }
        XCTAssertEqual(rowText(t, 20), "L20_", "precondition")
        // claude's real up-scroll: region 2..43, SD 1, reset.
        t.feed(byteArray: esc("\u{1b}[2;43r\u{1b}[1T\u{1b}[r"))
        // SD shifts region content DOWN by 1: row R shows old row R-1 for R in 2..42.
        print("SD after grow: row20=\(rowText(t, 20)) (want L19_)")
        XCTAssertEqual(rowText(t, 20), "L19_",
            "cmdScrollDown must shift the FULL width; if it stays L20_ only column 0 moved (the frozen-center bug)")
    }
}
