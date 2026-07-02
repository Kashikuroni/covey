# covey Prompt Answers (Slice 14) Implementation Plan

> **Executed with a deviation:** the reply composer (`i`, ReplySheet, drafts)
> was removed mid-slice by user decision — covey's terminal is live, so
> replying is a focus switch. Shipped: promptChanged end-to-end, `1-9`
> answers, prompt buttons on cards, `⇧Tab`. Composer steps below are
> historical.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Numbered-prompt options flow from the daemon to session cards and `1-9` keys; `i` opens a reply composer with TUI draft semantics; `⇧Tab` cycles the agent's mode.

**Architecture:** `StatusMonitor` gains `onPromptChanged` (options already computed each tick); a new `DaemonEvent.promptChanged` reaches `AppModel.promptsByName`. Choice = `"N\r"`, reply = `text + "\r"` (tmux.rs port). Drafts persist in the existing `drafts` schema field. Spec: `docs/superpowers/specs/2026-07-02-covey-reply-prompts-design.md`.

**Tech Stack:** Swift 6.3 / SwiftPM, `swiftLanguageMode(.v5)`, macOS 26, SwiftUI + Observation, XCTest. No new dependencies.

## Global Constraints

- All code, comments, and string literals in English (docs/ excepted).
- Git write operations are performed BY THE USER (batched after execution this slice).
- Draft semantics are the TUI's: Esc and empty-send save, successful send deletes.
- `⇧Tab` = `special == .tab && isShift` → `ESC[Z`; plain `Tab` keeps toggleTab and must require `!isShift`.
- Test run / full suite commands as in prior plans.

---

### Task 1: Daemon — promptChanged end to end

**Files:**
- Modify: `Sources/CoveydCore/StatusMonitor.swift`
- Modify: `Sources/CoveyKit/Protocol.swift`
- Modify: `Sources/CoveydCore/IPCServer.swift`
- Test: `Tests/CoveydCoreTests/StatusMonitorTests.swift`, `Tests/CoveyKitTests/ProtocolTests.swift` (append)

**Interfaces:**
- Produces: `StatusMonitor.onPromptChanged: ((String, [String]) -> Void)?`;
  `DaemonEvent.promptChanged(name: String, options: [String])`.

- [ ] **Step 1: Failing tests**

Append to `StatusMonitorTests`:

```swift
    func testPromptOptionsEmitOnChangeOnly() {
        var screens = ["s": "pick one:\n  1. yes\n  2. no"]
        let monitor = StatusMonitor(snapshot: { screens })
        let lock = NSLock()
        var events: [(String, [String])] = []
        monitor.onPromptChanged = { name, options in
            lock.lock(); events.append((name, options)); lock.unlock()
        }
        func captured() -> [(String, [String])] {
            lock.lock(); defer { lock.unlock() }; return events
        }
        monitor.tick()
        XCTAssertEqual(captured().last?.1, ["yes", "no"])
        monitor.tick()
        XCTAssertEqual(captured().count, 1, "unchanged prompt does not re-emit")
        screens["s"] = "done, moving on"
        monitor.tick()
        XCTAssertEqual(captured().last?.1, [], "prompt gone emits empty")
        screens = [:]
        monitor.tick()
        XCTAssertEqual(captured().count, 2, "already-empty prompt set stays quiet on prune")
    }

    func testPrunedSessionWithPromptEmitsEmpty() {
        var screens = ["s": "pick one:\n  1. yes\n  2. no"]
        let monitor = StatusMonitor(snapshot: { screens })
        let lock = NSLock()
        var events: [(String, [String])] = []
        monitor.onPromptChanged = { name, options in
            lock.lock(); events.append((name, options)); lock.unlock()
        }
        monitor.tick()
        screens = [:]
        monitor.tick()
        lock.lock(); let last = events.last; lock.unlock()
        XCTAssertEqual(last?.1, [], "killed session clears its prompt")
    }
```

Append to `ProtocolTests.testServerMessageRoundTrip` msgs array:

```swift
            .event(.promptChanged(name: "s-1", options: ["yes", "no"])),
```

- [ ] **Step 2: Verify red** (compile errors), **Step 3: Implement**

`Protocol.swift` — add to `DaemonEvent`:

```swift
    case promptChanged(name: String, options: [String])
```

`StatusMonitor.swift`:

```swift
    /// Fires when a session's detected prompt options change (empty = gone).
    public var onPromptChanged: ((String, [String]) -> Void)?
    private var prevPrompt: [String: [String]] = [:]
```

In `tickBody`, the loop already computes `prompt`; add:

```swift
            newPrompt[name] = prompt
            if prevPrompt[name, default: []] != prompt {
                onPromptChanged?(name, prompt)
            }
```

with `var newPrompt: [String: [String]] = [:]` at the top, and before the
wholesale map replacement:

```swift
        // Sessions that vanished while showing a prompt must clear it.
        for (name, options) in prevPrompt where newPrompt[name] == nil && !options.isEmpty {
            onPromptChanged?(name, [])
        }
        prevPrompt = newPrompt
```

`IPCServer.init` — next to the statusChanged subscription:

```swift
        monitor.onPromptChanged = { [weak self] name, options in
            self?.broadcast(.event(.promptChanged(name: name, options: options)))
        }
```

- [ ] **Step 4: Green + full suite.**

---

### Task 2: KeyRouter — 1-9, i, ⇧Tab

**Files:**
- Modify: `Sources/covey/KeyRouter.swift`
- Test: `Tests/CoveyAppTests/KeyRouterTests.swift` (append)

**Interfaces:**
- Produces: `KeyAction` cases `answerPrompt(Int)`, `openReply`, `sendShiftTab`.

- [ ] **Step 1: Failing tests**

```swift
    func testPromptAnswerReplyAndShiftTab() {
        XCTAssertEqual(KeyRouter.route(key("1"), context: ctx()), .answerPrompt(1))
        XCTAssertEqual(KeyRouter.route(key("9"), context: ctx()), .answerPrompt(9))
        XCTAssertEqual(KeyRouter.route(key("0"), context: ctx()), nil)
        XCTAssertEqual(KeyRouter.route(key("i"), context: ctx()), .openReply)
        XCTAssertEqual(KeyRouter.route(.init(char: nil, isShift: true, special: .tab),
                                       context: ctx()), .sendShiftTab)
        // plain tab still toggles tabs, select-mode digits still jump
        XCTAssertEqual(KeyRouter.route(special(.tab), context: ctx()), .toggleTab)
        XCTAssertEqual(KeyRouter.route(key("2"), context: ctx(mode: .selectSession)),
                       .selectByNumber(2))
    }
```

- [ ] **Step 2: red**, **Step 3: Implement**

Add the three cases to `KeyAction`. In `routeNormal`:
- special switch: `case .tab: return input.isShift ? .sendShiftTab : .toggleTab`
- char switch additions:

```swift
        case "i": return .openReply
        case let c? where c.wholeNumberValue.map({ (1...9).contains($0) }) == true:
            return .answerPrompt(c.wholeNumberValue!)
```

(implemented as a plain `default`-adjacent check: before the final `default`,
match digits via `if let n = ch?.wholeNumberValue, (1...9).contains(n) { return .answerPrompt(n) }`).

- [ ] **Step 4: Green.**

---

### Task 3: AppModel — prompts, drafts, reply actions

**Files:**
- Modify: `Sources/covey/AppModel.swift`
- Test: `Tests/CoveyAppTests/AppModelChromeTests.swift` (append)

**Interfaces:**
- Produces: `promptsByName`, `drafts`, `Modal.reply(String)`,
  `answerPrompt(_:session:)`, `sendReply(session:text:) -> Bool`,
  `saveDraft(session:text:)`, apply cases.

- [ ] **Step 1: Failing tests**

```swift
    @MainActor
    func testPromptEventsAndAnswer() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        // A shell session that renders a numbered menu and then echoes input.
        _ = try daemon.registry.create(
            dir: "/tmp", agent: "sh",
            argv: ["/bin/sh", "-c", "printf 'pick:\\n  1. yes\\n  2. no\\n'; exec cat"],
            name: "menu")
        await model.reconnect()
        _ = await eventually { model.sessions.count == 1 }
        daemon.monitor.tick()
        _ = await eventually { model.promptsByName["menu"] == ["yes", "no"] }
        await model.select("menu")
        model.apply(.answerPrompt(2))
        _ = await eventually {
            let bf = daemon.registry.backfill(name: "menu", since: 0)
            return bf.map { String(decoding: $0.bytes, as: UTF8.self).contains("2") } ?? false
        }
        daemon.registry.kill(name: "menu")
        _ = await eventually { model.sessions.isEmpty }
        XCTAssertNil(model.promptsByName["menu"], "kill clears the prompt")
    }

    @MainActor
    func testReplyDraftSemantics() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-drafts-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 0.05)
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(client: client,
                             makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                             store: store)
        await model.start()
        await model.create(dir: "/a", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = model.sessions[0].name
        await model.select(name)
        model.apply(.openReply)
        XCTAssertEqual(model.modal, .reply(name))
        model.saveDraft(session: name, text: "half-written")
        store.flush()
        XCTAssertEqual(store.load().drafts[name], "half-written")
        // empty send keeps the draft and reports "not sent"
        XCTAssertFalse(model.sendReply(session: name, text: "   "))
        XCTAssertEqual(model.drafts[name], "half-written")
        // real send deletes the draft
        XCTAssertTrue(model.sendReply(session: name, text: "hello agent"))
        XCTAssertNil(model.drafts[name])
        _ = await eventually {
            let bf = daemon.registry.backfill(name: name, since: 0)
            return bf.map { String(decoding: $0.bytes, as: UTF8.self).contains("hello agent") } ?? false
        }
        await model.kill(name)
    }
```

- [ ] **Step 2: red**, **Step 3: Implement**

1. `Modal` gains `case reply(String)`; `Sheets.swift` id switch gains
   `case .reply(let name): return "reply-\(name)"`.

2. State: `public private(set) var promptsByName: [String: [String]] = [:]`,
   `public private(set) var drafts: [String: String] = [:]`. `start()` loads
   `drafts = persisted.drafts`; `persist()` writes it back.

3. Event apply: `case let .promptChanged(name, options): promptsByName[name] =
   options.isEmpty ? nil : options` and in `.sessionRemoved`/`.exited` add
   `promptsByName[name] = nil`.

4. Methods:

```swift
    /// tmux.rs send_choice port: the digit plus Enter.
    public func answerPrompt(_ n: Int, session: String? = nil) {
        guard let target = session ?? selected,
              let options = promptsByName[target], n >= 1, n <= options.count
        else { return }
        Task { try? await client.input(name: target, bytes: Array("\(n)\r".utf8)) }
    }
```

```swift
    @discardableResult
    public func sendReply(session: String, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            saveDraft(session: session, text: text)
            modal = nil
            return false
        }
        drafts[session] = nil
        persist()
        Task { try? await client.input(name: session, bytes: Array((trimmed + "\r").utf8)) }
        modal = nil
        return true
    }

    public func saveDraft(session: String, text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts[session] = nil
        } else {
            drafts[session] = text
        }
        persist()
    }
```

5. `apply` cases:

```swift
        case .answerPrompt(let n):
            answerPrompt(n)
        case .openReply:
            if let selected { modal = .reply(selected) }
        case .sendShiftTab:
            guard let selected else { return }
            Task { try? await client.input(name: selected, bytes: [0x1b, 0x5b, 0x5a]) }
```

- [ ] **Step 4: Green + full suite.**

---

### Task 4: UI — ReplySheet, card buttons, hints

**Files:**
- Modify: `Sources/covey/Views/Sheets.swift` (ReplySheet)
- Modify: `Sources/covey/Views/ContentView.swift` (sheet case)
- Modify: `Sources/covey/Views/SessionListView.swift` (prompt buttons row)
- Modify: `Sources/covey/Views/StatusBar.swift` (contextual hints)

- [ ] **Step 1: ReplySheet**

```swift
struct ReplySheet: View {
    let model: AppModel
    let name: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reply → \(name)").font(.headline)
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .frame(minHeight: 120)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }  // newline
                    model.sendReply(session: name, text: text)
                    return .handled
                }
                .onExitCommand {
                    model.saveDraft(session: name, text: text)
                    model.modal = nil
                }
            Text("enter send · shift+enter newline · esc save draft")
                .font(.caption2).foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Cancel") {
                    model.saveDraft(session: name, text: text)
                    model.modal = nil
                }
                Button("Send") { model.sendReply(session: name, text: text) }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            text = model.drafts[name] ?? ""
            focused = true
        }
    }
}
```

ContentView sheet switch gains
`case .reply(let name): ReplySheet(model: model, name: name)`.

- [ ] **Step 2: Prompt buttons on cards (SessionListView.row)**

Wrap the existing row HStack in a VStack and add below it:

```swift
            if let options = model.promptsByName[session.name], !options.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(options.prefix(9).enumerated()), id: \.offset) { idx, label in
                        Button("\(idx + 1) \(label)") {
                            Task { await model.select(session.name) }
                            model.answerPrompt(idx + 1, session: session.name)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .lineLimit(1)
                    }
                }
            }
```

- [ ] **Step 3: StatusBar contextual hints**

In `hints`, `case .normal` (vim branch) becomes:

```swift
        case .normal:
            guard model.vimMode else { return "⌘N new · ⌘F filter" }
            var base = "n new · enter attach · d kill · space menu · / filter · ? help"
            if let selected = model.selected {
                if !(model.promptsByName[selected] ?? []).isEmpty { base += " · 1-9 answer" }
                if model.drafts[selected] != nil { base += " · i draft" }
            }
            return base
```

- [ ] **Step 4: Build + full suite.**

---

### Task 5: Smoke (user) + batched commits

Smoke per spec §7. Then all commits in one batch:

```bash
git add Sources/CoveydCore/StatusMonitor.swift Sources/CoveyKit/Protocol.swift Sources/CoveydCore/IPCServer.swift Tests/CoveydCoreTests/StatusMonitorTests.swift Tests/CoveyKitTests/ProtocolTests.swift
git commit -m "feat(coveyd): promptChanged event with numbered-menu options"

git add Sources/covey/KeyRouter.swift Tests/CoveyAppTests/KeyRouterTests.swift
git commit -m "feat(covey): router actions — answer prompt, reply, shift-tab"

git add Sources/covey/AppModel.swift Tests/CoveyAppTests/AppModelChromeTests.swift
git commit -m "feat(covey): prompt state, drafts and reply actions"

git add Sources/covey/Views/Sheets.swift Sources/covey/Views/ContentView.swift Sources/covey/Views/SessionListView.swift Sources/covey/Views/StatusBar.swift
git commit -m "feat(covey): reply sheet, prompt buttons on cards, contextual hints"

git add docs/superpowers/specs/2026-07-02-covey-reply-prompts-design.md docs/superpowers/plans/2026-07-02-covey-reply-prompts.md
git commit -m "docs: slice 14 spec + plan — reply composer and prompt answers"
```

## Definition of Done (spec §7)

1. Build + full suite green.
2. Smoke: card buttons, `1-9`, composer Enter/⇧↵/Esc-draft cycle, `⇧Tab`.
3. Vim off: card buttons clickable; composer is a vim affordance.
