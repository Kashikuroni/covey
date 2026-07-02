# covey Notes (Slice 13) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Session (`t`) and project (`T`) markdown notes in the Inspector with checkbox tasks, done/total counters on cards and group headers, and `space s R` project rename.

**Architecture:** `NoteModel.swift` is a 1:1 pure port of `amux-core/note.rs`; `AppModel` gains persisted `notes/projectNotes/projectNames` plus transient `noteTarget`/`NoteUIState`; the KeyRouter grows a `.note` mode (armed-clear interpreted in `apply`, router stays stateless). `NotePane` renders inside `InspectorView`. Spec: `docs/superpowers/specs/2026-07-02-covey-notes-design.md`.

**Tech Stack:** Swift 6.3 / SwiftPM, `swiftLanguageMode(.v5)`, macOS 26, SwiftUI + Observation, XCTest. No new dependencies.

## Global Constraints

- All code, comments, and string literals in English (docs/ excepted).
- Git write operations are performed BY THE USER; each task ends with the exact command.
- NoteModel semantics must match `crates/amux-core/src/note.rs` exactly (strict `- [ ]`/`- [x]` task syntax, heading level cap 6, bullets `- `/`* `, indentation preserved by toggle).
- Empty note/name deletes its dictionary key (no empty-string litter in state.json).
- Test run: `swift build --build-tests`, then
  `xcrun xctest -XCTest <Target>.<Class> .build/arm64-apple-macosx/debug/coveyPackageTests.xctest`.
- Full suite: `xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1`.

---

### Task 1: NoteModel — pure markdown-note logic

**Files:**
- Create: `Sources/covey/NoteModel.swift`
- Test: `Tests/CoveyAppTests/NoteModelTests.swift`

**Interfaces:**
- Produces (used by Tasks 3–4): `NoteLine`, `parseTask`, `parseNote`,
  `taskCounts`, `taskLineIndices`, `toggleTask`, `removeTasks`,
  `selectedAsNumbered` — signatures per spec §1.

- [ ] **Step 1: Write the compilable skeleton**

`Sources/covey/NoteModel.swift`:

```swift
import Foundation

/// A single parsed line of a note. Pure port of amux-core note.rs — only the
/// subset rendered specially is distinguished; everything else is `.text`.
enum NoteLine: Equatable {
    case task(done: Bool, text: String)
    case heading(level: Int, text: String)
    case bullet(String)
    case text(String)
    case blank
}

/// If `line` is a checkbox task, returns `(done, text)` with the `- [ ] `
/// prefix stripped; leading whitespace allowed. Strict: only `- [ ]`/`- [x]`
/// (or `X`) qualify, so body text mentioning "[ ]" never false-matches.
func parseTask(_ line: String) -> (done: Bool, text: String)? {
    nil
}

/// Parse a whole note buffer into typed lines (split on "\n").
func parseNote(_ buf: String) -> [NoteLine] {
    []
}

/// `(done, total)` task counts for the card progress indicator.
func taskCounts(_ buf: String) -> (done: Int, total: Int) {
    (0, 0)
}

/// Buffer line indices (0-based) that are tasks, in order; the position in
/// the result is the task ordinal.
func taskLineIndices(_ buf: String) -> [Int] {
    []
}

/// Flip the checkbox of the `ordinal`-th task; out-of-range is a no-op.
/// Preserves indentation and all other text.
func toggleTask(_ buf: String, ordinal: Int) -> String {
    buf
}

/// Delete the lines of the tasks whose ordinals are in `ordinals`.
func removeTasks(_ buf: String, ordinals: Set<Int>) -> String {
    buf
}

/// Render the given task ordinals as "1. text\n2. text", renumbered from 1
/// in the given order; unknown ordinals skipped.
func selectedAsNumbered(_ buf: String, ordinals: [Int]) -> String {
    ""
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/CoveyAppTests/NoteModelTests.swift`:

```swift
import XCTest
@testable import covey

final class NoteModelTests: XCTestCase {
    let sample = """
    # Plan
    - [ ] first
    - [x] second
    - not a task
    * bullet
    plain text

      - [X] indented done
    """

    func testParseTaskStrictness() {
        XCTAssertEqual(parseTask("- [ ] open")?.done, false)
        XCTAssertEqual(parseTask("- [x] closed")?.done, true)
        XCTAssertEqual(parseTask("  - [X] caps")?.text, "caps")
        XCTAssertNil(parseTask("-[ ] no space"))
        XCTAssertNil(parseTask("- [y] wrong mark"))
        XCTAssertNil(parseTask("text with [ ] inside"))
    }

    func testParseNoteLines() {
        let lines = parseNote(sample)
        XCTAssertEqual(lines[0], .heading(level: 1, text: "Plan"))
        XCTAssertEqual(lines[1], .task(done: false, text: "first"))
        XCTAssertEqual(lines[2], .task(done: true, text: "second"))
        XCTAssertEqual(lines[3], .bullet("not a task"))
        XCTAssertEqual(lines[4], .bullet("bullet"))
        XCTAssertEqual(lines[5], .text("plain text"))
        XCTAssertEqual(lines[6], .blank)
        XCTAssertEqual(lines[7], .task(done: true, text: "indented done"))
        XCTAssertEqual(parseNote("####### seven"), [.heading(level: 6, text: "seven")])
    }

    func testCountsAndIndices() {
        let c = taskCounts(sample)
        XCTAssertEqual(c.done, 2)
        XCTAssertEqual(c.total, 3)
        XCTAssertEqual(taskLineIndices(sample), [1, 2, 7])
    }

    func testToggleKeepsIndentAndText() {
        let toggled = toggleTask(sample, ordinal: 0)
        XCTAssertTrue(toggled.contains("- [x] first"))
        let back = toggleTask(toggled, ordinal: 0)
        XCTAssertEqual(back, sample)
        let indented = toggleTask(sample, ordinal: 2)
        XCTAssertTrue(indented.contains("  - [ ] indented done"), "indent preserved")
        XCTAssertEqual(toggleTask(sample, ordinal: 99), sample, "out of range no-op")
    }

    func testRemoveTasks() {
        let removed = removeTasks(sample, ordinals: [0, 2])
        XCTAssertFalse(removed.contains("first"))
        XCTAssertFalse(removed.contains("indented"))
        XCTAssertTrue(removed.contains("- [x] second"))
        XCTAssertTrue(removed.contains("# Plan"), "non-task lines untouched")
    }

    func testSelectedAsNumbered() {
        XCTAssertEqual(selectedAsNumbered(sample, ordinals: [2, 0]),
                       "1. indented done\n2. first")
        XCTAssertEqual(selectedAsNumbered(sample, ordinals: [99]), "")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveyAppTests.NoteModelTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
```

Expected: 6 tests, ≥5 failures.

- [ ] **Step 4: Implement (mirror note.rs)**

```swift
func parseTask(_ line: String) -> (done: Bool, text: String)? {
    let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
    guard trimmed.hasPrefix("- [") else { return nil }
    let chars = Array(trimmed)
    guard chars.count >= 5, chars[4] == "]" else { return nil }
    let done: Bool
    switch chars[3] {
    case " ": done = false
    case "x", "X": done = true
    default: return nil
    }
    let body = String(chars.dropFirst(5)).drop(while: { $0 == " " })
    return (done, String(body))
}

func parseNote(_ buf: String) -> [NoteLine] {
    buf.components(separatedBy: "\n").map(parseLine)
}

private func parseLine(_ line: String) -> NoteLine {
    if let task = parseTask(line) { return .task(done: task.done, text: task.text) }
    let trimmed = String(line.drop(while: { $0 == " " || $0 == "\t" }))
    if trimmed.isEmpty { return .blank }
    if trimmed.hasPrefix("#") {
        let level = min(6, trimmed.prefix(while: { $0 == "#" }).count)
        let text = String(trimmed.dropFirst(level)).drop(while: { $0 == " " })
        return .heading(level: level, text: String(text))
    }
    if trimmed.hasPrefix("- ") { return .bullet(String(trimmed.dropFirst(2))) }
    if trimmed.hasPrefix("* ") { return .bullet(String(trimmed.dropFirst(2))) }
    return .text(line)
}

func taskCounts(_ buf: String) -> (done: Int, total: Int) {
    var done = 0, total = 0
    for line in buf.components(separatedBy: "\n") {
        if let t = parseTask(line) {
            total += 1
            if t.done { done += 1 }
        }
    }
    return (done, total)
}

func taskLineIndices(_ buf: String) -> [Int] {
    buf.components(separatedBy: "\n").enumerated()
        .filter { parseTask($0.element) != nil }
        .map(\.offset)
}

func toggleTask(_ buf: String, ordinal: Int) -> String {
    var seen = 0
    let lines = buf.components(separatedBy: "\n").map { line -> String in
        guard let task = parseTask(line) else { return line }
        defer { seen += 1 }
        guard seen == ordinal else { return line }
        let leadCount = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        let lead = String(line.prefix(leadCount))
        let rest = String(line.dropFirst(leadCount))
        let mark = task.done ? " " : "x"
        return "\(lead)- [\(mark)]\(rest.dropFirst(5))"
    }
    return lines.joined(separator: "\n")
}

func removeTasks(_ buf: String, ordinals: Set<Int>) -> String {
    var seen = 0
    let lines = buf.components(separatedBy: "\n").filter { line in
        guard parseTask(line) != nil else { return true }
        defer { seen += 1 }
        return !ordinals.contains(seen)
    }
    return lines.joined(separator: "\n")
}

func selectedAsNumbered(_ buf: String, ordinals: [Int]) -> String {
    let texts = buf.components(separatedBy: "\n").compactMap { parseTask($0)?.text }
    var out: [String] = []
    for ord in ordinals where ord < texts.count {
        out.append("\(out.count + 1). \(texts[ord])")
    }
    return out.joined(separator: "\n")
}
```

- [ ] **Step 5: Run tests to verify they pass**

Same command. Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 6: Hand off commit to the user**

```bash
git add Sources/covey/NoteModel.swift Tests/CoveyAppTests/NoteModelTests.swift
git commit -m "feat(covey): NoteModel — pure markdown task logic (note.rs port)"
```

---

### Task 2: KeyRouter — note mode + t/T + s R

**Files:**
- Modify: `Sources/covey/KeyRouter.swift`
- Test: `Tests/CoveyAppTests/KeyRouterTests.swift` (append)

**Interfaces:**
- Produces: `InputMode.note`; `KeyAction` cases `toggleSessionNote`,
  `toggleProjectNote`, `noteCursor(down: Bool)`, `noteToggleTask`,
  `noteVisual`, `noteYank`, `noteDelete`, `noteEdit`, `noteArmClear`,
  `noteDefocus`, `noteEscape`, `renameProject`.

- [ ] **Step 1: Write the failing tests (append to KeyRouterTests)**

```swift
    func testNoteToggleKeysInNormalMode() {
        XCTAssertEqual(KeyRouter.route(key("t"), context: ctx()), .toggleSessionNote)
        XCTAssertEqual(KeyRouter.route(key("T"), context: ctx()), .toggleProjectNote)
        XCTAssertEqual(KeyRouter.route(key("е"), context: ctx()), .toggleSessionNote, "ЙЦУКЕН t")
    }

    func testNoteModeBindings() {
        let note = ctx(mode: .note)
        let cases: [(KeyInput, KeyAction)] = [
            (key("j"), .noteCursor(down: true)), (key("k"), .noteCursor(down: false)),
            (special(.down), .noteCursor(down: true)), (special(.up), .noteCursor(down: false)),
            (key(" "), .noteToggleTask),
            (key("V"), .noteVisual),
            (key("y"), .noteYank),
            (key("d"), .noteDelete),
            (key("e"), .noteEdit),
            (key("c"), .noteArmClear),
            (special(.tab), .noteDefocus),
            (special(.escape), .noteEscape),
        ]
        for (input, want) in cases {
            XCTAssertEqual(KeyRouter.route(input, context: note), want, "\(input)")
        }
        XCTAssertNil(KeyRouter.route(key("z"), context: note), "unbound ignored")
    }

    func testLeaderSessionRenameProject() {
        let session = ctx(mode: .leader(.session))
        XCTAssertEqual(KeyRouter.route(key("R"), context: session), .renameProject)
    }
```

- [ ] **Step 2: Run to verify failures**, **Step 3: Implement**

Add to `InputMode`: `case note`. Add the 12 new `KeyAction` cases. In
`route`, add `case .note: return routeNote(input, ch)`:

```swift
    private static func routeNote(_ input: KeyInput, _ ch: Character?) -> KeyAction? {
        switch input.special {
        case .down: return .noteCursor(down: true)
        case .up: return .noteCursor(down: false)
        case .tab: return .noteDefocus
        case .escape: return .noteEscape
        default: break
        }
        switch ch {
        case "j": return .noteCursor(down: true)
        case "k": return .noteCursor(down: false)
        case " ": return .noteToggleTask
        case "V": return .noteVisual
        case "y": return .noteYank
        case "d": return .noteDelete
        case "e": return .noteEdit
        case "c": return .noteArmClear
        default: return nil
        }
    }
```

In `routeNormal`'s char switch add `case "t": return .toggleSessionNote`
and `case "T": return .toggleProjectNote`. In `routeLeader` add
`case (.session, "R"): return .renameProject`.

- [ ] **Step 4: Run tests** (KeyRouterTests all green), **Step 5: commit**

```bash
git add Sources/covey/KeyRouter.swift Tests/CoveyAppTests/KeyRouterTests.swift
git commit -m "feat(covey): KeyRouter note mode + t/T + rename-project chord"
```

---

### Task 3: AppModel — note state, mutators, apply

**Files:**
- Modify: `Sources/covey/AppModel.swift`
- Test: `Tests/CoveyAppTests/AppModelChromeTests.swift` (append)

**Interfaces:**
- Produces (used by Task 4):
  - persisted: `notes`, `projectNotes`, `projectNames` (`[String: String]`),
    `setProjectName(dir:name:)`
  - `enum NoteTarget: Equatable { case session(String), project(String) }`,
    `noteTarget`, `struct NoteUIState`, `noteState`
  - `noteText()`, `setNoteText(_:)` (for the current target),
    `noteTitle()`, `displayName(forDir:)`
  - `Modal.renameProject(String)`
  - `apply` handling for all Task-2 actions

- [ ] **Step 1: Write the failing tests (append to AppModelChromeTests)**

```swift
    @MainActor
    func testNotesPersistAndCounters() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-notes-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 0.05)
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(client: client,
                             makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                             store: store)
        await model.start()
        model.setNote(session: "s1", text: "- [ ] a\n- [x] b")
        model.setProjectNote(dir: "/w", text: "- [ ] p")
        model.setProjectName(dir: "/w", name: "Web")
        store.flush()
        let back = store.load()
        XCTAssertEqual(back.notes["s1"], "- [ ] a\n- [x] b")
        XCTAssertEqual(back.projectNotes["/w"], "- [ ] p")
        XCTAssertEqual(back.projectNames["/w"], "Web")
        XCTAssertEqual(model.displayName(forDir: "/w"), "Web")
        model.setNote(session: "s1", text: "")
        model.setProjectName(dir: "/w", name: "")
        store.flush()
        XCTAssertNil(store.load().notes["s1"], "empty note drops the key")
        XCTAssertNil(store.load().projectNames["/w"], "empty name drops the override")
    }

    @MainActor
    func testNoteToggleFlowAndEditing() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/a", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = model.sessions[0].name
        await model.select(name)
        model.apply(.toggleSessionNote)
        XCTAssertEqual(model.noteTarget, .session(name))
        XCTAssertEqual(model.inputMode, .note)
        XCTAssertTrue(model.showInspector, "opening a note reveals the inspector")
        model.apply(.toggleSessionNote)
        XCTAssertNil(model.noteTarget, "second t closes")
        XCTAssertEqual(model.inputMode, .normal)
        model.apply(.toggleProjectNote)
        XCTAssertEqual(model.noteTarget, .project("/a"))
        model.setNoteText("- [ ] one\n- [ ] two")
        model.apply(.noteToggleTask)
        XCTAssertEqual(taskCounts(model.noteText()).done, 1)
        model.apply(.noteCursor(down: true))
        model.apply(.noteVisual)
        model.apply(.noteCursor(down: false))
        model.apply(.noteDelete)
        XCTAssertEqual(taskCounts(model.noteText()).total, 0, "visual delete removes both")
        model.setNoteText("- [ ] x")
        model.apply(.noteArmClear)
        model.apply(.noteCursor(down: true))   // any non-y key disarms, does nothing else
        XCTAssertEqual(model.noteText(), "- [ ] x")
        model.apply(.noteArmClear)
        model.apply(.noteYank)                 // armed + y wipes
        XCTAssertEqual(model.noteText(), "")
        model.apply(.noteEscape)
        XCTAssertNil(model.noteTarget)
        await model.kill(name)
    }

    @MainActor
    func testRenameProjectModal() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/a", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        await model.select(model.sessions[0].name)
        model.apply(.renameProject)
        XCTAssertEqual(model.modal, .renameProject("/a"))
        model.modal = nil
        await model.kill(model.sessions[0].name)
    }
```

- [ ] **Step 2: Run to verify compile failure**, **Step 3: Implement**

1. `Modal` gains `case renameProject(String)`. Find the `Identifiable`/id
   derivation for `Modal` (used by `.sheet(item:)`) and extend it the same
   way as `.rename`.

2. Types + state (near `NoteTarget` location of your choice, inside AppModel):

```swift
    public enum NoteTarget: Equatable {
        case session(String), project(String)
    }

    public struct NoteUIState: Equatable {
        public var cursor = 0
        public var visualAnchor: Int?
        public var editing = false
        public var clearArmed = false
    }
```

```swift
    public private(set) var notes: [String: String] = [:]
    public private(set) var projectNotes: [String: String] = [:]
    public private(set) var projectNames: [String: String] = [:]
    public private(set) var noteTarget: NoteTarget?
    public private(set) var noteState = NoteUIState()
```

3. `start()` loads the three dictionaries; `persist()` writes them back.

4. Mutators + helpers:

```swift
    public func setNote(session: String, text: String) {
        if text.isEmpty { notes[session] = nil } else { notes[session] = text }
        persist()
    }

    public func setProjectNote(dir: String, text: String) {
        if text.isEmpty { projectNotes[dir] = nil } else { projectNotes[dir] = text }
        persist()
    }

    public func setProjectName(dir: String, name: String) {
        if name.isEmpty { projectNames[dir] = nil } else { projectNames[dir] = name }
        persist()
    }

    public func displayName(forDir dir: String) -> String {
        projectNames[dir] ?? dir
    }

    public func noteText() -> String {
        switch noteTarget {
        case .session(let name): return notes[name] ?? ""
        case .project(let dir): return projectNotes[dir] ?? ""
        case nil: return ""
        }
    }

    public func setNoteText(_ text: String) {
        switch noteTarget {
        case .session(let name): setNote(session: name, text: text)
        case .project(let dir): setProjectNote(dir: dir, text: text)
        case nil: break
        }
    }

    public func noteTitle() -> String {
        switch noteTarget {
        case .session(let name): return name
        case .project(let dir): return displayName(forDir: dir)
        case nil: return ""
        }
    }

    public func setNoteEditing(_ on: Bool) {
        noteState.editing = on
        inputMode = on ? .normal : .note   // edit: NSTextView owns keys
    }
```

5. `apply` additions (new cases in the switch):

```swift
        case .toggleSessionNote:
            toggleNote(target: selected.map { .session($0) })
        case .toggleProjectNote:
            let dir = sessions.first(where: { $0.name == selected })?.dir
            toggleNote(target: dir.map { .project($0) })
        case .noteCursor(let down):
            if disarmClearIfNeeded() { return }
            let total = taskCounts(noteText()).total
            guard total > 0 else { return }
            let next = noteState.cursor + (down ? 1 : -1)
            noteState.cursor = min(total - 1, max(0, next))
        case .noteToggleTask:
            if disarmClearIfNeeded() { return }
            for ord in selectionOrdinals() { setNoteText(toggleTask(noteText(), ordinal: ord)) }
        case .noteVisual:
            if disarmClearIfNeeded() { return }
            noteState.visualAnchor = noteState.visualAnchor == nil ? noteState.cursor : nil
        case .noteYank:
            if noteState.clearArmed {
                noteState.clearArmed = false
                setNoteText("")
                noteState.cursor = 0
                noteState.visualAnchor = nil
                return
            }
            let list = selectedAsNumbered(noteText(), ordinals: selectionOrdinals())
            if !list.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(list, forType: .string)
            }
            noteState.visualAnchor = nil
        case .noteDelete:
            if disarmClearIfNeeded() { return }
            setNoteText(removeTasks(noteText(), ordinals: Set(selectionOrdinals())))
            noteState.visualAnchor = nil
            clampNoteCursor()
        case .noteEdit:
            if disarmClearIfNeeded() { return }
            setNoteEditing(true)
        case .noteArmClear:
            noteState.clearArmed = true
        case .noteDefocus:
            inputMode = .normal
        case .noteEscape:
            if noteState.clearArmed { noteState.clearArmed = false; return }
            if noteState.visualAnchor != nil { noteState.visualAnchor = nil; return }
            noteTarget = nil
            inputMode = .normal
        case .renameProject:
            inputMode = .normal
            if let dir = sessions.first(where: { $0.name == selected })?.dir {
                modal = .renameProject(dir)
            }
```

with the private helpers:

```swift
    private func toggleNote(target: NoteTarget?) {
        guard let target else { return }
        if noteTarget == target {
            noteTarget = nil
            inputMode = .normal
            return
        }
        noteTarget = target
        noteState = NoteUIState()
        inputMode = .note
        if !showInspector { setShowInspector(true) }
    }

    private func selectionOrdinals() -> [Int] {
        if let anchor = noteState.visualAnchor {
            let lo = min(anchor, noteState.cursor)
            let hi = max(anchor, noteState.cursor)
            return Array(lo...hi)
        }
        return [noteState.cursor]
    }

    private func clampNoteCursor() {
        let total = taskCounts(noteText()).total
        noteState.cursor = max(0, min(noteState.cursor, total - 1))
    }

    /// TUI semantics: while clear is armed, any key other than `y` only disarms.
    private func disarmClearIfNeeded() -> Bool {
        if noteState.clearArmed { noteState.clearArmed = false; return true }
        return false
    }
```

`import AppKit` joins AppModel's imports (NSPasteboard).

- [ ] **Step 4: Run tests + full suite**, **Step 5: commit**

```bash
git add Sources/covey/AppModel.swift Tests/CoveyAppTests/AppModelChromeTests.swift
git commit -m "feat(covey): note state, mutators and key actions in AppModel"
```

---

### Task 4: UI — NotePane, counters, rename sheet, hints

**Files:**
- Modify: `Sources/covey/Views/InspectorView.swift`
- Create: `Sources/covey/Views/NotePane.swift`
- Modify: `Sources/covey/Views/SessionListView.swift` (counters + display names)
- Modify: `Sources/covey/Views/Sheets.swift` (RenameProjectSheet)
- Modify: `Sources/covey/Views/ContentView.swift` (sheet switch case)
- Modify: `Sources/covey/Views/StatusBar.swift` (NOTE mode + hints)

**Interfaces:**
- Consumes: Task 1–3 APIs.

- [ ] **Step 1: InspectorView routes to NotePane**

```swift
struct InspectorView: View {
    let model: AppModel

    var body: some View {
        if model.noteTarget != nil {
            NotePane(model: model)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.right").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Inspector").font(.headline).foregroundStyle(.secondary)
                Text("t session note · T project note")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
```

(ContentView's `InspectorView()` call becomes `InspectorView(model: model)`.)

- [ ] **Step 2: NotePane**

`Sources/covey/Views/NotePane.swift`:

```swift
import SwiftUI

/// Markdown note with checkbox tasks (port of amux-tui ui/note.rs).
struct NotePane: View {
    @Bindable var model: AppModel
    @State private var editBuffer = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.noteState.editing { editor } else { rendered }
        }
    }

    private var header: some View {
        let counts = taskCounts(model.noteText())
        return HStack(spacing: 8) {
            Text(model.noteTitle()).fontWeight(.semibold).lineLimit(1)
            if counts.total > 0 {
                Text("\(counts.done)/\(counts.total)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.noteState.clearArmed {
                Text("y to clear").font(.caption).foregroundStyle(.red)
            }
            Button(model.noteState.editing ? "Done" : "Edit") {
                if model.noteState.editing { commitEdit() } else { startEdit() }
            }
            .buttonStyle(.borderless).font(.caption)
        }
        .padding(8)
    }

    private var rendered: some View {
        let lines = parseNote(model.noteText())
        var ordinal = -1
        let rows: [(line: NoteLine, ordinal: Int?)] = lines.map { line in
            if case .task = line { ordinal += 1; return (line, ordinal) }
            return (line, nil)
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    renderLine(row.line, ordinal: row.ordinal)
                }
                if model.noteText().isEmpty {
                    Text("e to start writing").font(.caption).foregroundStyle(.tertiary)
                        .padding(.top, 8)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func renderLine(_ line: NoteLine, ordinal: Int?) -> some View {
        switch line {
        case .task(let done, let text):
            let selected = ordinal.map(isSelected) ?? false
            HStack(spacing: 6) {
                Text(ordinal == model.noteState.cursor && model.inputMode == .note ? "›" : " ")
                    .foregroundStyle(.orange).fontWeight(.bold)
                Text(done ? "☑" : "☐")
                Text(text)
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
            }
            .font(.callout)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                if let ordinal { model.setNoteText(toggleTask(model.noteText(), ordinal: ordinal)) }
            }
        case .heading(_, let text):
            Text(text).font(.callout).fontWeight(.bold).padding(.top, 4)
        case .bullet(let text):
            HStack(spacing: 6) { Text("  •"); Text(text) }.font(.callout)
        case .text(let text):
            Text(text).font(.callout)
        case .blank:
            Text(" ").font(.caption2)
        }
    }

    private func isSelected(_ ordinal: Int) -> Bool {
        guard let anchor = model.noteState.visualAnchor else { return false }
        return (min(anchor, model.noteState.cursor)...max(anchor, model.noteState.cursor))
            .contains(ordinal)
    }

    private var editor: some View {
        TextEditor(text: $editBuffer)
            .font(.callout.monospaced())
            .focused($editorFocused)
            .onExitCommand { commitEdit() }
            .padding(4)
    }

    private func startEdit() {
        editBuffer = model.noteText()
        model.setNoteEditing(true)
        editorFocused = true
    }

    private func commitEdit() {
        model.setNoteText(editBuffer)
        model.setNoteEditing(false)
    }
}
```

plus an `.onChange(of: model.noteState.editing)` in `body` to sync
`editBuffer`/`editorFocused` when editing was started by the `e` key:

```swift
        .onChange(of: model.noteState.editing) { _, editing in
            if editing { editBuffer = model.noteText(); editorFocused = true }
        }
```

- [ ] **Step 3: Counters + display names in SessionListView**

In `row(_ session:)` add after the name `Text`:

```swift
            let counts = taskCounts(model.notes[session.name] ?? "")
            if counts.total > 0 {
                Text("\(counts.done)/\(counts.total)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
```

Replace `Section(group.dir)` with a header view:

```swift
                    Section {
                        ...rows unchanged...
                    } header: {
                        HStack(spacing: 6) {
                            Text(model.displayName(forDir: group.dir))
                            let pc = taskCounts(model.projectNotes[group.dir] ?? "")
                            if pc.total > 0 {
                                Text("\(pc.done)/\(pc.total)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
```

- [ ] **Step 4: RenameProjectSheet + ContentView case**

`Sheets.swift`:

```swift
struct RenameProjectSheet: View {
    let model: AppModel
    let dir: String
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename project").font(.headline)
            Text(dir).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            TextField("Display name (empty resets)", text: $name)
            HStack {
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Rename") {
                    model.setProjectName(dir: dir, name: name)
                    model.modal = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { name = model.projectNames[dir] ?? "" }
    }
}
```

ContentView sheet switch gains:

```swift
            case .renameProject(let dir): RenameProjectSheet(model: model, dir: dir)
```

- [ ] **Step 5: StatusBar**

`hints`: extend the `switch model.inputMode`:

```swift
        case .note:
            return "space toggle · e edit · d delete · V select · y yank · esc close"
```

`modeLabel` switch gains `case .note: return "NOTE"`.

- [ ] **Step 6: Build + full suite**, **Step 7: commit**

```bash
git add Sources/covey/Views/InspectorView.swift Sources/covey/Views/NotePane.swift Sources/covey/Views/SessionListView.swift Sources/covey/Views/Sheets.swift Sources/covey/Views/ContentView.swift Sources/covey/Views/StatusBar.swift
git commit -m "feat(covey): note pane in inspector, task counters, project rename sheet"
```

---

### Task 5: Manual smoke (spec §8 DoD) — by the user, then docs commit

```bash
git add docs/superpowers/plans/2026-07-02-covey-notes.md
git commit -m "docs: slice 13 implementation plan — notes"
```

## Definition of Done (spec §8)

1. Build + full suite green.
2. Keyboard smoke: t/e/Space/V-j-y/d/c-y/Esc/T/`space s R`; counters live and persist.
3. Vim off: mouse path works (checkbox clicks, Edit button).
