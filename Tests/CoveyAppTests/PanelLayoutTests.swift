import XCTest
@testable import covey

/// The workspace cards are inset from the window edges and separated by
/// gutters, so every width — and the drag that sets it — has to come off the
/// same inner width. These pin that arithmetic down.
final class PanelLayoutTests: XCTestCase {
    private func make(total: CGFloat, sessions: Bool = true, inspector: Bool = true,
                      splitPct: Int = 38, sbWidth: Int = 360) -> PanelLayout {
        PanelLayout.make(total: total, showSessions: sessions, showInspector: inspector,
                         splitPct: splitPct, sbWidth: sbWidth)
    }

    func testInnerWidthDropsEdgesAndGutters() {
        let layout = make(total: 1000)
        XCTAssertEqual(layout.inner, 1000 - Tokens.edge * 2 - Tokens.gutter * 2)
    }

    func testHidingAZoneDropsItsGutter() {
        let layout = make(total: 1000, inspector: false)
        XCTAssertEqual(layout.inner, 1000 - Tokens.edge * 2 - Tokens.gutter)
        XCTAssertEqual(layout.inspector, 0)
    }

    func testZonesFillTheInnerWidthExactly() {
        let layout = make(total: 1400)
        XCTAssertEqual(layout.sessions + layout.terminal + layout.inspector,
                       layout.inner, accuracy: 0.001)
    }

    func testSessionListStopsAtItsMinimum() {
        let layout = make(total: 1400, splitPct: 15)
        XCTAssertEqual(layout.sessions, PanelLayout.minSessions)
    }

    func testTerminalKeepsItsReserveWhenTheListGrows() {
        let layout = make(total: 1400, splitPct: 80)
        XCTAssertGreaterThanOrEqual(layout.terminal, PanelLayout.minTerminal,
                                    "terminal must keep its minimum when session list is at maximum")

        // Worst-case regression guard: inspector at max, split at max
        let worst = make(total: 1400, splitPct: 80, sbWidth: 600)
        XCTAssertGreaterThanOrEqual(worst.terminal, PanelLayout.minTerminal,
                                    "terminal reserve must account for inspector width")
    }

    func testNarrowWindowNeverOverflowsTheCards() {
        let layout = make(total: 500)
        XCTAssertGreaterThanOrEqual(layout.terminal, 0)
        XCTAssertLessThanOrEqual(layout.sessions + layout.inspector, layout.inner)
    }

    func testDraggingTheSplitReturnsTheWidthUnderTheCursor() {
        let layout = make(total: 1400)
        let wanted: CGFloat = 500
        let pct = PanelLayout.splitPercent(dragX: Tokens.edge + wanted, inner: layout.inner)
        let after = make(total: 1400, splitPct: pct)
        // `splitPercent` rounds to the nearest whole percent, so it can be off
        // by at most 0.5 percentage points from the exact value under the
        // cursor. Converting that back to a width multiplies by `inner`/100,
        // so the provable worst case is inner * 0.005 = 1368 * 0.005 = 6.84pt
        // (inner = 1400 - edge*2 - gutter*2 = 1368 with both zones shown).
        // 7 is the tightest whole-point bound that still covers it.
        XCTAssertEqual(after.sessions, wanted, accuracy: 7,
                       "the divider must land under the cursor, not a gutter away")
    }

    /// Regression guard for the case where a wide `sbWidth` combined with a
    /// wide `splitPct` used to hand the terminal exactly zero width (the
    /// inspector wasn't capped against it) — `CoveyTerminalView` holds output
    /// in an uncapped buffer until it gets a real grid, so that's a silent
    /// dead end rather than a visible squeeze.
    func testTerminalNeverStarvesAcrossWindowSizes() {
        for width in stride(from: CGFloat(400), through: 2000, by: 25) {
            for splitPct in [PanelLayout.minSessionSplitPercent, 38,
                             PanelLayout.maxSessionSplitPercent] {
                for sbWidth in [PanelLayout.minInspectorWidth, 360,
                                PanelLayout.maxInspectorWidth] {
                    let layout = make(total: width, splitPct: splitPct, sbWidth: sbWidth)
                    XCTAssertGreaterThan(layout.terminal, 0,
                        "terminal starved at width \(width), splitPct \(splitPct), sbWidth \(sbWidth)")
                }
            }
        }
    }

    func testWideWindowsCanUseNewSidebarMaxima() {
        let sessions = make(total: 6000, inspector: false,
                            splitPct: PanelLayout.maxSessionSplitPercent)
        XCTAssertEqual(sessions.sessions, sessions.inner * 0.90, accuracy: 0.001)

        let inspector = make(total: 2500, sessions: false,
                             sbWidth: PanelLayout.maxInspectorWidth)
        XCTAssertEqual(inspector.inspector, 1200)
        XCTAssertGreaterThanOrEqual(inspector.terminal, PanelLayout.minTerminalSliver)
    }

    func testInspectorDragMeasuresFromTheRightEdge() {
        let total: CGFloat = 1400
        XCTAssertEqual(PanelLayout.inspectorWidth(dragX: total - Tokens.edge - 300,
                                                  total: total), 300)
    }

    func testHiddenSessionListFreesWidthToTerminal() {
        let layout = make(total: 1400, sessions: false)
        XCTAssertEqual(layout.sessions, 0)
        XCTAssertEqual(layout.inner, 1400 - Tokens.edge * 2 - Tokens.gutter,
                       "hiding sessions drops its gutter from the count")
        XCTAssertEqual(layout.terminal + layout.inspector, layout.inner,
                       "freed width goes to terminal and inspector")
    }

    func testBothZonesHiddenDropsAllGutters() {
        let layout = make(total: 1400, sessions: false, inspector: false)
        XCTAssertEqual(layout.sessions, 0)
        XCTAssertEqual(layout.inspector, 0)
        XCTAssertEqual(layout.inner, 1400 - Tokens.edge * 2,
                       "no gutters when all zones are hidden")
        XCTAssertEqual(layout.terminal, layout.inner,
                       "terminal gets the full inner width")
    }
}

// MARK: - Split tree geometry (Split Session)

final class SplitFrameTests: XCTestCase {
    private let two = PaneNode.split(axis: .vertical, ratio: 0.5,
                                     first: .agent(session: "a"),
                                     second: .agent(session: "b"))
    private let size = CGSize(width: 1000, height: 500)
    private let gutter: CGFloat = 8

    func testVerticalSplitGivesRightPaneTheRemainder() {
        let f = PanelLayout.splitFrames(tree: two, companionShell: nil,
                                        companionRatio: 0.6, size: size, gutter: gutter)
        XCTAssertEqual(f.agentArea, CGRect(x: 0, y: 0, width: 1000, height: 500))
        let a = f.leaves["a"]!, b = f.leaves["b"]!
        XCTAssertEqual(a.width, b.width, accuracy: 0.5)      // ratio 0.5
        XCTAssertEqual(a.minX, 0); XCTAssertEqual(b.maxX, 1000, accuracy: 0.5)
        XCTAssertEqual(f.dividers.count, 1)
        XCTAssertEqual(f.dividers[0].path, [], "корневой узел — пустой index-path")
        XCTAssertEqual(f.dividers[0].axis, .vertical)
    }

    /// Ручка делителя обязана стоять В ШВЕ между панелями при ЛЮБОМ ratio.
    /// Она рисовалась по середине узла: при 0.5 совпадало, после первого же
    /// драга уезжала от шва — и «ресайз перестаёт работать».
    func testDividerHandleSitsInTheSeamAtEveryRatio() {
        for ratio in [0.3, 0.5, 0.7] {
            let tree = PaneNode.split(axis: .vertical, ratio: ratio,
                                      first: .agent(session: "a"), second: .agent(session: "b"))
            let f = PanelLayout.splitFrames(tree: tree, companionShell: nil,
                                            companionRatio: 0.6, size: size, gutter: gutter)
            let a = f.leaves["a"]!, b = f.leaves["b"]!
            let handle = f.dividers[0].handle

            XCTAssertEqual(handle.minX, a.maxX, accuracy: 0.5,
                           "ручка начинается там, где кончается левая панель (ratio \(ratio))")
            XCTAssertEqual(handle.maxX, b.minX, accuracy: 0.5,
                           "и кончается там, где начинается правая (ratio \(ratio))")
            XCTAssertEqual(handle.width, gutter, accuracy: 0.5)
            XCTAssertEqual(handle.height, size.height, accuracy: 0.5)
        }
    }

    func testHorizontalDividerHandleSpansTheSeam() {
        let tree = PaneNode.split(axis: .horizontal, ratio: 0.7,
                                  first: .agent(session: "a"), second: .agent(session: "b"))
        let f = PanelLayout.splitFrames(tree: tree, companionShell: nil,
                                        companionRatio: 0.6, size: size, gutter: gutter)
        let a = f.leaves["a"]!, b = f.leaves["b"]!
        let handle = f.dividers[0].handle

        XCTAssertEqual(handle.minY, a.maxY, accuracy: 0.5)
        XCTAssertEqual(handle.maxY, b.minY, accuracy: 0.5)
        XCTAssertEqual(handle.height, gutter, accuracy: 0.5)
        XCTAssertEqual(handle.width, size.width, accuracy: 0.5)
    }

    func testDragClampKeepsRatioWithinBounds() {
        let skewed = PaneNode.split(axis: .vertical, ratio: 0.99,
                                    first: .agent(session: "a"), second: .agent(session: "b"))
        let f = PanelLayout.splitFrames(tree: skewed, companionShell: nil,
                                        companionRatio: 0.6, size: size, gutter: gutter)
        // 0.85 кламп: a ≤ 85% + паддинги, b ≥ 15%
        XCTAssertLessThanOrEqual(f.leaves["a"]!.width, 1000 * 0.85 + 0.5)
        XCTAssertGreaterThanOrEqual(f.leaves["b"]!.width, 1000 * 0.15 - gutter - 0.5)
    }

    func testLeafFloorEnforcedWhenItFits() {
        let f = PanelLayout.splitFrames(tree: two, companionShell: nil,
                                        companionRatio: 0.02, size: size, gutter: gutter)
        // Даже при ratio→0 первый лист держит пол 120pt.
        XCTAssertGreaterThanOrEqual(f.leaves["a"]!.width, PanelLayout.minSplitPane - 0.5)
    }

    func testFloorDegradesToEqualShareWhenPanelsDoNotFit() {
        // 8 листьев по вертикали в 900pt: равная доля (900-56)/8 ≈ 105.5 < 120
        // → пол невыполним → равный дележ, ratio игнорируется. Дерево
        // сбалансированное: у каждого узла по 4 листа в ветке, поэтому
        // пропорциональный дележ даёт строго равные листья (гуттеры симметричны).
        let pair: (String, String) -> PaneNode = {
            .split(axis: .vertical, ratio: 0.5,
                   first: .agent(session: $0), second: .agent(session: $1))
        }
        let eight = PaneNode.split(axis: .vertical, ratio: 0.5,
                                   first: PaneNode.split(axis: .vertical, ratio: 0.5,
                                                         first: pair("s1", "s2"),
                                                         second: pair("s3", "s4")),
                                   second: PaneNode.split(axis: .vertical, ratio: 0.5,
                                                          first: pair("s5", "s6"),
                                                          second: pair("s7", "s8")))
        let narrow = CGSize(width: 900, height: 500)
        let f = PanelLayout.splitFrames(tree: eight, companionShell: nil,
                                        companionRatio: 0.6, size: narrow, gutter: gutter)
        let widths = (1...8).map { f.leaves["s\($0)"]!.width }
        for w in widths {
            XCTAssertEqual(w, widths[0], accuracy: 0.5, "все листья равны")
            XCTAssertEqual(w, (900 - 7 * gutter) / 8, accuracy: 0.5)
        }
    }

    func testCompanionColumnSplitsTheWidthAndCarriesItsOwnRatio() {
        let f = PanelLayout.splitFrames(tree: two, companionShell: "a+sh",
                                        companionRatio: 0.6, size: size, gutter: gutter)
        let area = f.agentArea!, col = f.companion!
        XCTAssertEqual(area.width + gutter + col.width, 1000, accuracy: 0.5)
        XCTAssertEqual(area.width / (area.width + col.width), 0.6, accuracy: 0.02)
        XCTAssertEqual(f.leaves["b"]!.maxX, area.maxX, accuracy: 0.5,
                       "правый лист дерева упирается в край agent-области")
    }

    func testSoloAgentFillsTheAreaWhenTreeIsNil() {
        // Инвариант дерева: один лист ⇒ splitTree == nil. Панель всё равно
        // должна быть отрисована — иначе agent-область пустая (регрессия).
        let f = PanelLayout.splitFrames(tree: nil, soloAgent: "a",
                                        companionShell: "a+sh",
                                        companionRatio: 0.6, size: size, gutter: gutter)
        XCTAssertEqual(f.leaves["a"], f.agentArea,
                       "одиночная панель занимает всю agent-область")
        XCTAssertTrue(f.dividers.isEmpty, "делят внутри дерева нет")
    }

    func testSoloAgentWithoutCompanionTakesTheWholeSize() {
        let f = PanelLayout.splitFrames(tree: nil, soloAgent: "a", companionShell: nil,
                                        companionRatio: 0.6, size: size, gutter: gutter)
        XCTAssertEqual(f.leaves["a"], CGRect(origin: .zero, size: size))
        XCTAssertNil(f.companion)
    }

    func testSoloAgentIsIgnoredWhenTreeExists() {
        let f = PanelLayout.splitFrames(tree: two, soloAgent: "zzz", companionShell: nil,
                                        companionRatio: 0.6, size: size, gutter: gutter)
        XCTAssertNil(f.leaves["zzz"], "дерево — источник истины при не-nil")
        XCTAssertEqual(f.leaves.count, 2)
    }

    func testFirstBranchSizeDegradationUnit() {
        // Пол невыполним (равная доля 112.5 < 120) → пропорция листьев 3/8,
        // ratio игнорируется: 900 × 3/8 = 337.5.
        XCTAssertEqual(PanelLayout.firstBranchSize(requested: 0.9, available: 900,
                                                   firstLeaves: 3, secondLeaves: 5,
                                                   gutter: 0),
                       337.5, accuracy: 0.5)
        // Пол выполним → драг-кламп 0.85.
        XCTAssertEqual(PanelLayout.firstBranchSize(requested: 0.9, available: 2000,
                                                   firstLeaves: 1, secondLeaves: 1,
                                                   gutter: 0),
                       1700, accuracy: 0.5)
    }
}
