import XCTest
import SwiftUI
@testable import covey
import CoveyKit

/// Remounting an agent pane hands the session a fresh emulator that never saw
/// its `?1049h`. Without a re-attach (the preamble only flows on attach) the
/// pane drops out of the alternate buffer and wheel routing degrades to
/// `.viewport` — "scroll stops working until the app restarts". Switching
/// sessions remounts by design (`.id(name)`); toggling the split must NOT —
/// the agent pane keeps one structural position for every shape of the View.
@MainActor
final class TerminalPaneRemountTests: XCTestCase {
    private func terminalViews(in root: NSView) -> [CoveyTerminalView] {
        var found: [CoveyTerminalView] = []
        func walk(_ view: NSView) {
            if let term = view as? CoveyTerminalView { found.append(term) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    private func coordinator(
        named name: String,
        in root: NSView
    ) -> TerminalRepresentable.Coordinator? {
        terminalViews(in: root)
            .compactMap {
                $0.terminalDelegate as? TerminalRepresentable.Coordinator
            }
            .first { $0.name == name }
    }

    private func view(named name: String, in root: NSView) -> CoveyTerminalView? {
        terminalViews(in: root).first {
            ($0.terminalDelegate as? TerminalRepresentable.Coordinator)?.name == name
        }
    }

    private func restoredAgentView(in root: NSView) -> CoveyTerminalView? {
        terminalViews(in: root).first {
            $0.getTerminal().isCurrentBufferAlternate
                && $0.getTerminal().keyboardEnhancementFlags.rawValue == 1
        }
    }

    private func assertShiftEnterIsKittyEncoded(
        by view: CoveyTerminalView,
        in window: NSWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let probe = TerminalInputProbe()
        // Панель переживает toggle сплита, поэтому делегат возвращается на
        // место: иначе следующая проверка не найдёт координатор панели.
        let real = view.terminalDelegate
        defer { view.terminalDelegate = real }
        view.terminalDelegate = probe
        XCTAssertTrue(window.makeFirstResponder(view), file: file, line: line)
        sendReturnKey(to: view, modifiers: [.shift])
        XCTAssertEqual(
            probe.sent,
            Array("\u{1b}[13;2u".utf8),
            file: file,
            line: line
        )
    }

    func testSplitToggleKeepsAgentAltBufferAndKittyKeyboardState() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(
            dir: "/usr", agent: "claude",
            // Overflow the 1 MB ring so the original Kitty push cannot mask a
            // missing synthesized preamble when each fresh view attaches.
            argv: ["/bin/sh", "-c",
                   "printf '\\033[?1049h\\033[>1u\\033[?1003h\\033[?1006h'; "
                   + "/usr/bin/yes x | /usr/bin/head -c 1001000; "
                   + "printf 'READY'; exec cat"],
            name: "agent")
        _ = try daemon.registry.create(
            dir: "/usr", agent: "claude", argv: ["/bin/cat"], name: "agent-b")
        _ = await eventually { model.sessions.contains { $0.name == "agent" } }
        _ = await eventually {
            daemon.registry.backfill(name: "agent", since: 0)?.gapped == true
        }
        await model.select("agent")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: TerminalPaneView(model: model))

        let mounted = await eventually {
            guard let root = window.contentView else { return false }
            return self.restoredAgentView(in: root) != nil
        }
        XCTAssertTrue(mounted, "agent pane should restore alt buffer and Kitty flags")
        let initialCoordinator = try XCTUnwrap(
            window.contentView.flatMap {
                coordinator(named: "agent", in: $0)
            }
        )
        XCTAssertTrue(model.isTerminalViewLeaseCurrent(initialCoordinator.lease))

        model.perform(.splitTerminalVertically)
        await model.splitPickerChosen(.init(kind: .session("agent-b"), label: "agent-b"))
        _ = await eventually { model.activeView?.leaves.count == 2 }
        let openRestored = await eventually {
            guard let root = window.contentView else { return false }
            return self.terminalViews(in: root).count == 2
                && self.restoredAgentView(in: root) != nil
        }
        XCTAssertTrue(openRestored,
                      "agent pane must restore Kitty flags after split open")
        let splitCoordinator = try XCTUnwrap(
            window.contentView.flatMap {
                coordinator(named: "agent", in: $0)
            }
        )
        XCTAssertEqual(initialCoordinator.lease, splitCoordinator.lease,
                       "открытие сплита не пересобирает панель агента")
        XCTAssertTrue(model.isTerminalViewLeaseCurrent(splitCoordinator.lease))
        if let root = window.contentView,
           let agentView = restoredAgentView(in: root) {
            assertShiftEnterIsKittyEncoded(by: agentView, in: window)
        } else {
            XCTFail("restored agent view missing after split open")
        }

        model.perform(.closeTerminalSplit)
        _ = await eventually { (model.activeView.map { !$0.isSplit } ?? true) }
        let closeRestored = await eventually {
            guard let root = window.contentView else { return false }
            return self.terminalViews(in: root).count == 1
                && self.restoredAgentView(in: root) != nil
        }
        XCTAssertTrue(closeRestored,
                      "agent pane must restore Kitty flags after split close")
        let restoredCoordinator = try XCTUnwrap(
            window.contentView.flatMap {
                coordinator(named: "agent", in: $0)
            }
        )
        XCTAssertEqual(splitCoordinator.lease, restoredCoordinator.lease,
                       "закрытие сплита не пересобирает панель агента")
        XCTAssertTrue(model.isTerminalViewLeaseCurrent(restoredCoordinator.lease))
        if let root = window.contentView,
           let agentView = restoredAgentView(in: root) {
            assertShiftEnterIsKittyEncoded(by: agentView, in: window)
        } else {
            XCTFail("restored agent view missing after split close")
        }

        daemon.registry.kill(name: "agent")
    }

    func testSessionSwitchRotatesAgentResizeLease() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()

        _ = try daemon.registry.create(
            dir: "/usr",
            agent: "cat",
            argv: ["/bin/cat"],
            name: "agent-a"
        )
        _ = try daemon.registry.create(
            dir: "/usr",
            agent: "cat",
            argv: ["/bin/cat"],
            name: "agent-b"
        )
        let loaded = await eventually {
            model.sessions.contains { $0.name == "agent-a" }
                && model.sessions.contains { $0.name == "agent-b" }
        }
        XCTAssertTrue(loaded)

        await model.select("agent-a")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(
            rootView: TerminalPaneView(model: model)
        )

        let firstMounted = await eventually {
            guard let root = window.contentView else { return false }
            return self.coordinator(named: "agent-a", in: root) != nil
        }
        XCTAssertTrue(firstMounted)
        let firstCoordinator = try XCTUnwrap(
            window.contentView.flatMap {
                coordinator(named: "agent-a", in: $0)
            }
        )
        XCTAssertTrue(model.isTerminalViewLeaseCurrent(firstCoordinator.lease))

        await model.select("agent-b")
        let secondSessionMounted = await eventually {
            guard let root = window.contentView else { return false }
            return self.coordinator(named: "agent-b", in: root) != nil
        }
        XCTAssertTrue(secondSessionMounted)

        await model.select("agent-a")
        let replacementMounted = await eventually {
            guard let root = window.contentView,
                  let coordinator = self.coordinator(
                    named: "agent-a",
                    in: root
                  ) else { return false }
            return coordinator.lease != firstCoordinator.lease
        }
        XCTAssertTrue(replacementMounted)
        let replacementCoordinator = try XCTUnwrap(
            window.contentView.flatMap {
                coordinator(named: "agent-a", in: $0)
            }
        )

        XCTAssertFalse(
            model.isTerminalViewLeaseCurrent(firstCoordinator.lease)
        )
        XCTAssertTrue(
            model.isTerminalViewLeaseCurrent(replacementCoordinator.lease)
        )

        daemon.registry.kill(name: "agent-a")
        daemon.registry.kill(name: "agent-b")
    }

    /// ⌘[ / ⌘] переключают сессию через `select()`. Заголовок панели при этом
    /// загорается (focus == .terminal, focusedPane == новая панель), поэтому
    /// клавиатура обязана уехать в новую панель — иначе панель «в фокусе», но
    /// не принимает ввод, и приходится доводить фокус вручную через ⌃2.
    func testSessionSwitchHandsTheKeyboardToTheNewPane() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        for name in ["agent-a", "agent-b"] {
            _ = try daemon.registry.create(dir: "/usr", agent: "cat",
                                           argv: ["/bin/cat"], name: name)
        }
        _ = await eventually { model.sessions.count == 2 }
        await model.select("agent-a")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSHostingView(rootView: TerminalPaneView(model: model))
        window.contentView = root
        _ = await eventually { self.view(named: "agent-a", in: root) != nil }

        model.perform(.focusAgent)                       // ⌃2
        let a = try XCTUnwrap(view(named: "agent-a", in: root))
        XCTAssertIdentical(window.firstResponder, a, "предусловие: клавиатура в панели a")

        await model.select("agent-b")                    // ⌘]
        let mounted = await eventually { self.view(named: "agent-b", in: root) != nil }
        XCTAssertTrue(mounted)
        XCTAssertEqual(model.focusedPane, "agent-b", "модель считает панель b фокусной")
        XCTAssertEqual(model.focus, .terminal, "зона фокуса осталась терминальной")

        let b = try XCTUnwrap(view(named: "agent-b", in: root))
        let grabbed = await eventually(timeout: 1) { window.firstResponder === b }
        XCTAssertTrue(grabbed, "новая панель должна забрать клавиатуру без ⌃2")

        daemon.registry.kill(name: "agent-a")
        daemon.registry.kill(name: "agent-b")
    }

    /// Та же проверка, но в конфигурации со скриншота: рядом стоит
    /// шелл-колонка (`companionShell`), agent-панель одна.
    func testSessionSwitchHandsTheKeyboardOverWithAShellColumn() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/usr", agent: "cat",
                                       argv: ["/bin/cat"], name: "agent-a")
        // Печатает маркер: вывод сессии должен оказаться в панели на экране.
        _ = try daemon.registry.create(
            dir: "/usr", agent: "cat",
            argv: ["/bin/sh", "-c", "printf 'HELLO-B'; exec cat"], name: "agent-b")
        _ = await eventually { model.sessions.count == 2 }
        await model.select("agent-a")
        await model.toggleActiveTerminal()
        _ = await eventually { model.activeView?.terminal?.shellSession != nil }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSHostingView(rootView: TerminalPaneView(model: model))
        window.contentView = root
        _ = await eventually { self.view(named: "agent-a", in: root) != nil }

        model.perform(.focusAgent)                       // ⌃2
        let a = try XCTUnwrap(view(named: "agent-a", in: root))
        XCTAssertIdentical(window.firstResponder, a, "предусловие: клавиатура в панели a")

        await model.select("agent-b")                    // ⌘]
        let mounted = await eventually { self.view(named: "agent-b", in: root) != nil }
        XCTAssertTrue(mounted, "панель b смонтирована")
        let b = try XCTUnwrap(view(named: "agent-b", in: root))
        let grabbed = await eventually(timeout: 1) { window.firstResponder === b }
        XCTAssertTrue(grabbed, "новая панель должна забрать клавиатуру без ⌃2")

        daemon.registry.kill(name: "agent-a")
        daemon.registry.kill(name: "agent-b")
    }

    /// То же переключение, но в полном окне (сайдбар + панель), как в приложении.
    func testSessionSwitchHandsKeyboardOverInTheFullWindow() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        for name in ["agent-a", "agent-b"] {
            _ = try daemon.registry.create(dir: "/usr", agent: "cat",
                                           argv: ["/bin/cat"], name: name)
        }
        _ = await eventually { model.sessions.count == 2 }
        await model.select("agent-a")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSHostingView(rootView: ContentView(model: model))
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        _ = await eventually { self.view(named: "agent-a", in: root) != nil }

        model.perform(.focusAgent)                       // ⌃2
        let a = try XCTUnwrap(view(named: "agent-a", in: root))
        XCTAssertIdentical(window.firstResponder, a, "предусловие: клавиатура в панели a")

        model.perform(.selectNextSession)                // ⌘]
        let mounted = await eventually { self.view(named: "agent-b", in: root) != nil }
        XCTAssertTrue(mounted, "панель b смонтирована")
        let b = try XCTUnwrap(view(named: "agent-b", in: root))
        let grabbed = await eventually(timeout: 1) { window.firstResponder === b }
        XCTAssertTrue(grabbed,
                      "клавиатура должна уехать в b; responder=\(String(describing: window.firstResponder))")

        daemon.registry.kill(name: "agent-a")
        daemon.registry.kill(name: "agent-b")
    }

    /// Сессия вне сплита показывается одна; клик по сессии сплита
    /// возвращает всю сетку на экран.
    func testSplitHidesForAnOutsideSessionAndComesBack() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        for name in ["agent-a", "agent-b", "agent-c"] {
            _ = try daemon.registry.create(dir: "/usr", agent: "cat",
                                           argv: ["/bin/cat"], name: name)
        }
        _ = await eventually { model.sessions.count == 3 }
        await model.select("agent-a")
        model.perform(.splitTerminalVertically)
        await model.splitPickerChosen(.init(kind: .session("agent-b"), label: "agent-b"))
        _ = await eventually { model.activeView?.leaves.count == 2 }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSHostingView(rootView: TerminalPaneView(model: model))
        window.contentView = root
        _ = await eventually { self.terminalViews(in: root).count == 2 }

        await model.select("agent-c")

        let hidden = await eventually { self.terminalViews(in: root).count == 1 }
        XCTAssertTrue(hidden, "на экране одна панель")
        XCTAssertNotNil(view(named: "agent-c", in: root))
        XCTAssertNil(view(named: "agent-a", in: root), "сетка убрана с экрана")

        await model.select("agent-a")

        let restored = await eventually { self.terminalViews(in: root).count == 2 }
        XCTAssertTrue(restored, "сетка вернулась целиком")
        XCTAssertNotNil(view(named: "agent-a", in: root))
        XCTAssertNotNil(view(named: "agent-b", in: root))
        XCTAssertNil(view(named: "agent-c", in: root))

        for n in ["agent-a", "agent-b", "agent-c"] { daemon.registry.kill(name: n) }
    }

    func testTerminalPaneSeparatesContentAndScrollerInsets() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()

        _ = try daemon.registry.create(
            dir: "/usr",
            agent: "cat",
            argv: ["/bin/cat"],
            name: "agent"
        )
        _ = await eventually {
            model.sessions.contains { $0.name == "agent" }
        }
        await model.select("agent")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let root = NSHostingView(rootView: TerminalPaneView(model: model))
        window.contentView = root

        let mounted = await eventually {
            self.terminalViews(in: root).count == 1
        }
        XCTAssertTrue(mounted)
        root.layoutSubtreeIfNeeded()

        let terminal = try XCTUnwrap(terminalViews(in: root).first)
        let frame = terminal.convert(terminal.bounds, to: root)
        let scroller = try XCTUnwrap(
            terminal.subviews.compactMap { $0 as? NSScroller }.first
        )
        let scrollerFrame = scroller.convert(scroller.bounds, to: root)
        let leadingGap = frame.minX - root.bounds.minX
        let scrollerTrailingGap = root.bounds.maxX - scrollerFrame.maxX
        let bottomGap = root.isFlipped
            ? root.bounds.maxY - frame.maxY
            : frame.minY - root.bounds.minY
        let topGap = root.isFlipped
            ? frame.minY - root.bounds.minY
            : root.bounds.maxY - frame.maxY

        XCTAssertEqual(leadingGap, 8, accuracy: 0.5)
        XCTAssertEqual(scrollerTrailingGap, 4, accuracy: 0.5)
        XCTAssertEqual(bottomGap, 4, accuracy: 0.5)
        // Заголовок в две строки: зона + «<проект> - <сессия>».
        XCTAssertEqual(topGap, 42, accuracy: 0.5)

        daemon.registry.kill(name: "agent")
    }

    /// Скриншот-баг «agent-панель пустая, пока не откроешь терминал».
    ///
    /// Уход с View с открытым терминалом на View без него переключает
    /// структурную ветку `TerminalPaneView`, и SwiftUI успевает создать ВТОРУЮ
    /// панель той же сессии, а затем снести её. Аренда и вывод-сток заведены
    /// по имени сессии по принципу «последний mount выигрывает», поэтому их
    /// забирает обречённый view: живой на экране остаётся без байтов сессии
    /// (пустой экран) и без resize (`verdict":"stale-lease"` в pane-layout.log),
    /// пока следующий remount — открытие терминала — не пересоберёт панель.
    func testPaneStaysLiveAfterLeavingAViewWithATerminal() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/usr", agent: "cat",
                                       argv: ["/bin/cat"], name: "agent-a")
        // Печатает маркер: вывод сессии должен оказаться в панели на экране.
        _ = try daemon.registry.create(
            dir: "/usr", agent: "cat",
            argv: ["/bin/sh", "-c", "printf 'HELLO-B'; exec cat"], name: "agent-b")
        _ = await eventually { model.sessions.count == 2 }
        await model.select("agent-a")
        await model.toggleActiveTerminal()
        _ = await eventually { model.activeView?.terminal?.shellSession != nil }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSHostingView(rootView: TerminalPaneView(model: model))
        window.contentView = root
        _ = await eventually { self.view(named: "agent-a", in: root) != nil }
        root.layoutSubtreeIfNeeded()

        await model.select("agent-b")                    // ⌘] — у b терминала нет
        _ = await eventually { self.view(named: "agent-b", in: root) != nil }
        _ = await eventually { self.view(named: "agent-a", in: root) == nil }
        root.layoutSubtreeIfNeeded()

        let b = try XCTUnwrap(view(named: "agent-b", in: root))
        let lease = try XCTUnwrap(
            (b.terminalDelegate as? TerminalRepresentable.Coordinator)?.lease)
        XCTAssertTrue(model.isTerminalViewLeaseCurrent(lease),
                      "панель на экране владеет сессией — иначе её resize глушится")

        let printed = await eventually { Self.contents(of: b).contains("HELLO-B") }
        XCTAssertTrue(printed, "вывод сессии доходит до панели на экране")

        daemon.registry.kill(name: "agent-a")
        daemon.registry.kill(name: "agent-b")
    }

    /// Всё содержимое сетки одной строкой.
    private static func contents(of view: CoveyTerminalView) -> String {
        let terminal = view.getTerminal()
        return (0..<terminal.rows).map {
            terminal.getScrollInvariantLine(row: $0)?
                .translateToString(trimRight: true) ?? ""
        }.joined()
    }

    /// Страховка на случай, если SwiftUI когда-нибудь снова смонтирует панель
    /// дважды: сессия обязана вернуться живой панели вместе с вывозом — и
    /// владением (resize), и повтором вывода. Панели заводятся напрямую через
    /// контракт модели: `makeNSView` руками не вызвать.
    func testSessionGoesBackToTheSurvivingPaneWhenTheOwnerIsTornDown() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(
            dir: "/usr", agent: "cat",
            argv: ["/bin/sh", "-c", "printf 'HELLO'; exec cat"], name: "agent")
        _ = await eventually { model.sessions.count == 1 }
        await model.select("agent")
        _ = await eventually { model.attachedNames.contains("agent") }

        var survivor: [UInt8] = []
        let survivorLease = model.mountTerminalView("agent")
        model.registerPane(survivorLease) {
            model.setTerminalSink(for: "agent") { survivor += $0 }
        }
        model.paneViewMounted("agent")
        _ = await eventually { String(decoding: survivor, as: UTF8.self).contains("HELLO") }
        let beforeHandover = survivor.count

        // Переходное двойное монтирование: вторая панель той же сессии
        // перехватывает владение и тут же сносится.
        var doomed: [UInt8] = []
        let doomedLease = model.mountTerminalView("agent")
        model.registerPane(doomedLease) {
            model.setTerminalSink(for: "agent") { doomed += $0 }
        }
        XCTAssertFalse(model.isTerminalViewLeaseCurrent(survivorLease),
                       "предусловие: сессией владеет вторая панель")

        model.unmountTerminalView(doomedLease)

        XCTAssertTrue(model.isTerminalViewLeaseCurrent(survivorLease),
                      "владение вернулось живой панели — её resize снова доходит")
        let refed = await eventually { survivor.count > beforeHandover }
        XCTAssertTrue(refed, "живая панель получила сток и повтор вывода сессии")

        daemon.registry.kill(name: "agent")
    }

    /// Ушла последняя панель сессии — сток снимается, и вывод копится до
    /// следующей панели. Иначе он молча уходит в снесённую: та ещё жива (её
    /// держит замыкание), и потеря вывода никак себя не проявляет.
    func testOutputWaitsForTheNextPaneWhenTheLastOneIsGone() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(
            dir: "/usr", agent: "cat",
            argv: ["/bin/sh", "-c", "printf 'HELLO'; exec cat"], name: "agent")
        _ = await eventually { model.sessions.count == 1 }
        await model.select("agent")
        _ = await eventually { model.attachedNames.contains("agent") }

        var gone: [UInt8] = []
        let lease = model.mountTerminalView("agent")
        model.registerPane(lease) { model.setTerminalSink(for: "agent") { gone += $0 } }
        model.paneViewMounted("agent")
        _ = await eventually { String(decoding: gone, as: UTF8.self).contains("HELLO") }
        let deliveredToPane = gone.count

        model.unmountTerminalView(lease)
        model.paneViewMounted("agent")          // демон повторяет вывод сессии
        try await Task.sleep(nanoseconds: 300_000_000)   // повтор успевает долететь

        XCTAssertEqual(gone.count, deliveredToPane,
                       "снесённая панель больше не получает вывод")
        var next: [UInt8] = []
        model.setTerminalSink(for: "agent") { next += $0 }
        let delivered = await eventually {
            String(decoding: next, as: UTF8.self).contains("HELLO")
        }
        XCTAssertTrue(delivered, "вывод дождался следующей панели в буфере")

        daemon.registry.kill(name: "agent")
    }


    /// Панели сплита обязаны стоять ровно по кадрам `PanelLayout` — раскладка
    /// переехала с `.offset` (двигает только отрисовку; зона попадания
    /// делителей оставалась в неcдвинутом кадре) на `.position`, и этот тест
    /// держит, что картинка от переезда не поехала.
    func testSplitPanesLandOnTheirLayoutFrames() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        for name in ["agent-a", "agent-b"] {
            _ = try daemon.registry.create(dir: "/usr", agent: "cat",
                                           argv: ["/bin/cat"], name: name)
        }
        _ = await eventually { model.sessions.count == 2 }
        await model.select("agent-a")
        model.perform(.splitTerminalVertically)
        await model.splitPickerChosen(.init(kind: .session("agent-b"), label: "agent-b"))
        _ = await eventually { model.activeView?.leaves.count == 2 }
        await model.toggleActiveTerminal()
        _ = await eventually { model.activeView?.terminal?.shellSession != nil }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSHostingView(rootView: TerminalPaneView(model: model))
        window.contentView = root
        _ = await eventually { self.terminalViews(in: root).count == 3 }
        root.layoutSubtreeIfNeeded()

        let frames = PanelLayout.splitFrames(
            tree: model.visibleSplitTree, soloAgent: model.selected,
            companionShell: model.activeView?.terminal?.shellSession,
            companionRatio: model.activeView?.agentAreaRatio ?? 0.6,
            size: root.bounds.size, gutter: Tokens.gutter)

        // Терминал сидит внутри карточки с известными отступами, поэтому
        // сверяем не кадр в кадр, а что панель попала в свой прямоугольник.
        for (name, frame) in frames.leaves {
            let view = try XCTUnwrap(self.view(named: name, in: root), name)
            let onScreen = view.convert(view.bounds, to: root)
            XCTAssertTrue(frame.insetBy(dx: -1, dy: -1).contains(onScreen),
                          "\(name): \(onScreen) вне своего кадра \(frame)")
        }
        let shell = try XCTUnwrap(model.activeView?.terminal?.shellSession)
        let column = try XCTUnwrap(frames.companion)
        let shellView = try XCTUnwrap(self.view(named: shell, in: root))
        let shellFrame = shellView.convert(shellView.bounds, to: root)
        XCTAssertTrue(column.insetBy(dx: -1, dy: -1).contains(shellFrame),
                      "шелл-колонка \(shellFrame) вне своего кадра \(column)")
        // И панели не наезжают друг на друга — шов остаётся свободным.
        let a = try XCTUnwrap(frames.leaves["agent-a"])
        let b = try XCTUnwrap(frames.leaves["agent-b"])
        XCTAssertEqual(b.minX - a.maxX, Tokens.gutter, accuracy: 0.5)

        for n in ["agent-a", "agent-b"] { daemon.registry.kill(name: n) }
    }
}
