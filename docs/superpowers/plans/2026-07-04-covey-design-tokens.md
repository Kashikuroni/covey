# covey Design Tokens + Card Session List (Slice 19) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the amux-desktop design system (surfaces, text tiers, status colors, borders, radii, shadows — dark+light) into a Swift `Tokens` type and rebuild the session list as amux-style cards (variant A: border + shadow + status stripe), with ages on Recent rows.

**Architecture:** `Tokens` is a plain struct with two static instances (`.dark`/`.light`, values 1:1 from `crates/amux-desktop/assets/style.css` `:root` and `.app.light`), selected by the existing `Theme` enum — the single color source for the SwiftUI layer (SwiftTerm's `Theme.swift` palette stays separate). `SessionListView` swaps plain rows for cards drawn entirely from tokens; the system List highlight is disabled (the card renders selection). `RecentSession` gains an optional `stoppedAt` for the age column (`humanizeAge` port of timeutil.rs). Spec: `docs/superpowers/specs/2026-07-04-covey-design-tokens-design.md`.

**Tech Stack:** Swift 6.3 / SwiftPM, SwiftUI, XCTest.

## Global Constraints

- All code, comments, and string literals in English (docs/ excepted).
- Git write operations are performed BY THE USER; each task ends with the exact command.
- Token values are copied EXACTLY from style.css — dark from `:root` (lines 13-21), light from `.app.light` (lines 28-36); no invented colors.
- Topbar, statusbar, inspector, sheets, terminal palette: NOT in this slice.
- `verified` status and `sr-goal` are NOT ported.
- Test runs: `swift test --filter <ClassName>`; full suite: `swift test`.

---

### Task 1: CoveyKit — humanizeAge + RecentSession.stoppedAt

**Files:**
- Modify: `Sources/CoveyKit/PersistedState.swift:15-23`
- Modify: `Sources/covey/AppModel.swift:144,742` (pushRecent call sites)
- Test: `Tests/CoveyKitTests/PersistedStateTests.swift`

**Interfaces:**
- Produces (used by Task 3):

```swift
public func humanizeAge(_ secs: Int64) -> String       // "42s" / "5m" / "3h" / "2d"
// RecentSession gains:
public var stoppedAt: Int64?                            // epoch seconds, optional
public init(name: String, dir: String, agent: String,
            resumeCmd: String? = nil, stoppedAt: Int64? = nil)
```

- [ ] **Step 1: Failing tests** — append to `Tests/CoveyKitTests/PersistedStateTests.swift`:

```swift
    func testHumanizeAge() {
        XCTAssertEqual(humanizeAge(0), "0s")
        XCTAssertEqual(humanizeAge(59), "59s")
        XCTAssertEqual(humanizeAge(60), "1m")
        XCTAssertEqual(humanizeAge(3599), "59m")
        XCTAssertEqual(humanizeAge(3600), "1h")
        XCTAssertEqual(humanizeAge(86_399), "23h")
        XCTAssertEqual(humanizeAge(86_400), "1d")
        XCTAssertEqual(humanizeAge(-5), "0s", "clock skew clamps to zero")
    }

    func testRecentSessionStoppedAtRoundTripsAndOldPayloadDecodes() throws {
        let r = RecentSession(name: "a", dir: "/d", agent: "claude",
                              resumeCmd: "claude --resume u", stoppedAt: 1_700_000_000)
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(RecentSession.self, from: data)
        XCTAssertEqual(back, r)
        // Payload written before the field existed decodes with stoppedAt nil.
        let old = #"{"name":"b","dir":"/d","agent":"sh"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RecentSession.self, from: old)
        XCTAssertNil(decoded.stoppedAt)
        XCTAssertNil(decoded.resumeCmd)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PersistedStateTests`
Expected: FAIL — `humanizeAge`/`stoppedAt` undefined (compile errors).

- [ ] **Step 3: Implement** — in `Sources/CoveyKit/PersistedState.swift` replace the `RecentSession` struct:

```swift
public struct RecentSession: Codable, Equatable {
    public var name: String
    public var dir: String
    public var agent: String
    public var resumeCmd: String?
    /// Epoch seconds when the session stopped; optional so payloads written
    /// before the field existed keep decoding.
    public var stoppedAt: Int64?
    public init(name: String, dir: String, agent: String,
                resumeCmd: String? = nil, stoppedAt: Int64? = nil) {
        self.name = name; self.dir = dir; self.agent = agent
        self.resumeCmd = resumeCmd; self.stoppedAt = stoppedAt
    }
}
```

and add below `pushRecent`:

```swift
/// Compact age string (port of timeutil.rs humanize_age): 42s, 5m, 3h, 2d.
public func humanizeAge(_ secs: Int64) -> String {
    let s = max(0, secs)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86_400 { return "\(s / 3600)h" }
    return "\(s / 86_400)d"
}
```

- [ ] **Step 4: Stamp the two pushRecent call sites** — in `Sources/covey/AppModel.swift`, both `RecentSession(...)` constructions (`:144` lost-sessions loop, `:742` exited handler) gain the argument:

```swift
                pushRecent(&recents, RecentSession(name: s.name, dir: s.dir, agent: s.agent,
                                                   resumeCmd: s.resumeCmd,
                                                   stoppedAt: Int64(Date().timeIntervalSince1970)))
```

(identical change at both sites; the surrounding lines differ — one loops over `lost`, the other handles `.exited`).

- [ ] **Step 5: Green + full suite**

Run: `swift test --filter PersistedStateTests && swift test`
Expected: PASS.

- [ ] **Step 6: Hand the commit to the user**

```bash
git add Sources/CoveyKit/PersistedState.swift Sources/covey/AppModel.swift Tests/CoveyKitTests/PersistedStateTests.swift
git commit -m "feat(coveykit): recent stoppedAt timestamp + humanizeAge (timeutil port)"
```

---

### Task 2: Tokens.swift — the ported design system

**Files:**
- Create: `Sources/covey/Tokens.swift`
- Test: `Tests/CoveyAppTests/TokensTests.swift` (new)

**Interfaces:**
- Consumes: `Theme` (existing enum in `Sources/covey/Theme.swift`).
- Produces (used by Task 3):

```swift
struct Tokens {
    // surfaces
    let bg, surface, surf2, surf3, surf4, card, cardHover, termBg: Color
    // borders (three densities)
    let bd, bd2, bd3: Color
    // text tiers
    let t1, t2, t3, t4: Color
    // status + diff
    let run, wait, idle, ok, err, warn, diffAdd, diffDel: Color
    // card shadow (primary component of --sh)
    let shadowColor: Color
    static let r: CGFloat = 6
    static let rSm: CGFloat = 4
    static let rLg: CGFloat = 10
    static let shadowRadius: CGFloat = 8
    static let shadowY: CGFloat = 2
    static let dark: Tokens
    static let light: Tokens
    init(_ theme: Theme)          // .dark → .dark, .light → .light
}
extension Color { init(hex: UInt32) }   // internal, sRGB, opaque
```

- [ ] **Step 1: Failing spot-check test** — create `Tests/CoveyAppTests/TokensTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import covey

final class TokensTests: XCTestCase {
    func testDarkPortMatchesStyleCSS() {
        XCTAssertEqual(Tokens.dark.bg, Color(hex: 0x1C1917))
        XCTAssertEqual(Tokens.dark.card, Color(hex: 0x332E2A))
        XCTAssertEqual(Tokens.dark.t1, Color(hex: 0xFAF7F2))
        XCTAssertEqual(Tokens.dark.run, Color(hex: 0xE8926A))
        XCTAssertEqual(Tokens.dark.wait, Color(hex: 0xD4A843))
    }

    func testLightPortMatchesStyleCSS() {
        XCTAssertEqual(Tokens.light.bg, Color(hex: 0xF8F9FA))
        XCTAssertEqual(Tokens.light.card, Color(hex: 0xFFFFFF))
        XCTAssertEqual(Tokens.light.run, Color(hex: 0xF29718))
    }

    func testThemeSelectionAndConstants() {
        XCTAssertEqual(Tokens(Theme(raw: "dark")).bg, Tokens.dark.bg)
        XCTAssertEqual(Tokens(Theme(raw: "light")).bg, Tokens.light.bg)
        XCTAssertEqual(Tokens.r, 6)
        XCTAssertEqual(Tokens.rSm, 4)
        XCTAssertEqual(Tokens.rLg, 10)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter TokensTests`
Expected: FAIL — `Tokens` undefined.

- [ ] **Step 3: Implement** — create `Sources/covey/Tokens.swift`:

```swift
import SwiftUI

/// The design system ported 1:1 from amux-desktop (assets/style.css :root /
/// .app.light). Single color source for the SwiftUI layer; the terminal's
/// NSColor palette (Theme.swift) stays separate.
struct Tokens {
    // surfaces
    let bg: Color, surface: Color, surf2: Color, surf3: Color, surf4: Color
    let card: Color, cardHover: Color, termBg: Color
    // borders, three densities
    let bd: Color, bd2: Color, bd3: Color
    // text tiers, brightest to dimmest
    let t1: Color, t2: Color, t3: Color, t4: Color
    // status + diff accents
    let run: Color, wait: Color, idle: Color, ok: Color, err: Color, warn: Color
    let diffAdd: Color, diffDel: Color
    // card shadow (the primary component of --sh)
    let shadowColor: Color

    static let r: CGFloat = 6
    static let rSm: CGFloat = 4
    static let rLg: CGFloat = 10
    static let shadowRadius: CGFloat = 8
    static let shadowY: CGFloat = 2

    init(_ theme: Theme) {
        self = theme == .dark ? .dark : .light
    }

    private init(bg: Color, surface: Color, surf2: Color, surf3: Color, surf4: Color,
                 card: Color, cardHover: Color, termBg: Color,
                 bd: Color, bd2: Color, bd3: Color,
                 t1: Color, t2: Color, t3: Color, t4: Color,
                 run: Color, wait: Color, idle: Color, ok: Color, err: Color, warn: Color,
                 diffAdd: Color, diffDel: Color, shadowColor: Color) {
        self.bg = bg; self.surface = surface; self.surf2 = surf2
        self.surf3 = surf3; self.surf4 = surf4
        self.card = card; self.cardHover = cardHover; self.termBg = termBg
        self.bd = bd; self.bd2 = bd2; self.bd3 = bd3
        self.t1 = t1; self.t2 = t2; self.t3 = t3; self.t4 = t4
        self.run = run; self.wait = wait; self.idle = idle
        self.ok = ok; self.err = err; self.warn = warn
        self.diffAdd = diffAdd; self.diffDel = diffDel
        self.shadowColor = shadowColor
    }

    static let dark = Tokens(
        bg: Color(hex: 0x1C1917), surface: Color(hex: 0x242120),
        surf2: Color(hex: 0x2E2A27), surf3: Color(hex: 0x38332F),
        surf4: Color(hex: 0x443E39),
        card: Color(hex: 0x332E2A), cardHover: Color(hex: 0x3C3733),
        termBg: Color(hex: 0x141210),
        bd: Color(hex: 0xFAF7F2).opacity(0.07),
        bd2: Color(hex: 0xFAF7F2).opacity(0.13),
        bd3: Color(hex: 0xFAF7F2).opacity(0.22),
        t1: Color(hex: 0xFAF7F2), t2: Color(hex: 0xE0D8CE),
        t3: Color(hex: 0x9A9088), t4: Color(hex: 0x6A6058),
        run: Color(hex: 0xE8926A), wait: Color(hex: 0xD4A843),
        idle: Color(hex: 0x38332F), ok: Color(hex: 0x7AAF85),
        err: Color(hex: 0xD46A5A), warn: Color(hex: 0xC88040),
        diffAdd: Color(hex: 0x7AAF85), diffDel: Color(hex: 0xD46A5A),
        shadowColor: Color.black.opacity(0.45))

    static let light = Tokens(
        bg: Color(hex: 0xF8F9FA), surface: Color(hex: 0xF1F3F5),
        surf2: Color(hex: 0xE9ECEF), surf3: Color(hex: 0xDEE2E6),
        surf4: Color(hex: 0xCED4DA),
        card: Color(hex: 0xFFFFFF), cardHover: Color(hex: 0xFAFBFC),
        termBg: Color(hex: 0xFAFAFA),
        bd: Color(hex: 0x6B7D8F).opacity(0.12),
        bd2: Color(hex: 0x6B7D8F).opacity(0.20),
        bd3: Color(hex: 0x6B7D8F).opacity(0.32),
        t1: Color(hex: 0x5C6166), t2: Color(hex: 0x787B80),
        t3: Color(hex: 0x828E9F), t4: Color(hex: 0xABB2BD),
        run: Color(hex: 0xF29718), wait: Color(hex: 0xBC8A0A),
        idle: Color(hex: 0xCED4DA), ok: Color(hex: 0x57922B),
        err: Color(hex: 0xD14545), warn: Color(hex: 0xC2701C),
        diffAdd: Color(hex: 0x57922B), diffDel: Color(hex: 0xD14545),
        shadowColor: Color(hex: 0x6B7D8F).opacity(0.12))
}

extension Color {
    /// Opaque sRGB color from 0xRRGGBB.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
```

- [ ] **Step 4: Green**

Run: `swift test --filter TokensTests`
Expected: PASS.

- [ ] **Step 5: Hand the commit to the user**

```bash
git add Sources/covey/Tokens.swift Tests/CoveyAppTests/TokensTests.swift
git commit -m "feat(covey): design tokens ported from amux-desktop style.css"
```

---

### Task 3: SessionListView — cards, headers, recent rows

**Files:**
- Modify: `Sources/covey/Views/SessionListView.swift` (activeList, recentList, row)

**Interfaces:**
- Consumes: `Tokens` (Task 2), `humanizeAge`/`stoppedAt` (Task 1), existing `model.visibleSessionNames()`, `isReturnable`, `taskCounts`, `fuzzyMatch`, `collapseHome`.
- Produces: visual-only.

- [ ] **Step 1: Shared bits** — inside `struct SessionListView` add:

```swift
    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    /// mono helper matching the amux type scale
    private func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
```

- [ ] **Step 2: activeList rework** — replace the `activeList` body:

```swift
    private var activeList: some View {
        let groups = model.orderedSessions()
        let filtering = !model.filter.isEmpty
        // Card numbers match selectByNumber: position in the flat visible order.
        let numbers = Dictionary(uniqueKeysWithValues:
            model.visibleSessionNames().enumerated().map { ($1, $0 + 1) })
        return List(selection: selectionBinding) {
            ForEach(groups, id: \.dir) { group in
                let rows = group.sessions.filter { fuzzyMatch(model.filter, $0.name) }
                if !rows.isEmpty {
                    Section {
                        ForEach(rows, id: \.name) { session in
                            card(session, number: numbers[session.name] ?? 0)
                                .tag(session.name)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 2.5, leading: 8,
                                                          bottom: 2.5, trailing: 8))
                                .contextMenu {
                                    Button("Rename…") { model.modal = .rename(session.name) }
                                    Button("Kill…", role: .destructive) { model.modal = .kill(session.name) }
                                }
                        }
                        .onMove { from, to in
                            guard !filtering else { return }
                            model.moveSession(inDir: group.dir, from: from, to: to)
                        }
                    } header: {
                        projectHeader(group: group, rows: rows)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(tk.surface)
    }

    private func projectHeader(group: (dir: String, sessions: [Session]),
                               rows: [Session]) -> some View {
        let running = rows.filter { model.statusByName[$0.name] == .running }.count
        return HStack(spacing: 6) {
            Text(model.displayName(forDir: group.dir).uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(tk.t4)
            let pc = taskCounts(model.projectNotes[group.dir] ?? "")
            if pc.total > 0 {
                Text("\(pc.done)/\(pc.total)").font(mono(10)).foregroundStyle(tk.t4)
            }
            Spacer()
            Text("\(running)/\(rows.count)").font(mono(11)).foregroundStyle(tk.t4)
        }
    }
```

- [ ] **Step 3: The card** — replace `row(_:)` and `statusColor(_:)`:

```swift
    private func card(_ session: Session, number: Int) -> some View {
        let selected = model.selected == session.name
        let status = model.statusByName[session.name] ?? .idle
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(number > 0 ? "\(number)" : "")
                    .font(mono(10)).foregroundStyle(tk.t4)
                    .frame(width: 13, alignment: .trailing)
                statusDot(status)
                Text(session.name)
                    .font(mono(13, .medium))
                    .foregroundStyle(selected ? tk.t1 : (status == .waiting ? tk.wait : tk.t2))
                    .lineLimit(1)
                let counts = taskCounts(model.notes[session.name] ?? "")
                if counts.total > 0 {
                    Text("\(counts.done)/\(counts.total)")
                        .font(mono(10)).foregroundStyle(tk.t4)
                }
                Spacer()
                Text(statusLabel(status))
                    .font(mono(11)).foregroundStyle(statusLabelColor(status))
            }
            Group {
                if isReturnable(session) {
                    Text("⧉ worktree removed — space g r returns to root")
                        .font(mono(11)).foregroundStyle(tk.t4)
                } else if let git = session.git {
                    HStack(spacing: 6) {
                        Text(session.agent).font(mono(11)).foregroundStyle(tk.t3)
                        HStack(spacing: 3) {
                            Text(session.worktreeRepo != nil ? "⧉" : "⎇")
                                .font(.system(size: 10)).foregroundStyle(tk.t4)
                            Text(git.branch).font(mono(11)).foregroundStyle(tk.t3)
                                .lineLimit(1)
                        }
                        Spacer()
                        if git.added > 0 || git.removed > 0 {
                            HStack(spacing: 4) {
                                if git.added > 0 {
                                    Text("+\(git.added)")
                                        .foregroundStyle(tk.diffAdd.opacity(0.65))
                                }
                                if git.removed > 0 {
                                    Text("−\(git.removed)")
                                        .foregroundStyle(tk.diffDel.opacity(0.65))
                                }
                            }
                            .font(mono(11))
                        }
                    }
                } else {
                    Text(session.agent).font(mono(11)).foregroundStyle(tk.t3)
                }
            }
            .padding(.leading, 19)
            if let options = model.promptsByName[session.name], !options.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(options.prefix(9).enumerated()), id: \.offset) { idx, label in
                        Button("\(idx + 1) \(label)") {
                            Task { await model.select(session.name) }
                            model.answerPrompt(idx + 1, session: session.name)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.mini)
                        .lineLimit(1)
                    }
                }
                .padding(.leading, 19)
            }
        }
        .padding(EdgeInsets(top: 7, leading: 11, bottom: 8, trailing: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? tk.cardHover : tk.card,
                    in: RoundedRectangle(cornerRadius: Tokens.r))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.r)
                .strokeBorder(selected ? tk.bd3 : tk.bd))
        .overlay(alignment: .leading) {
            // The amux status stripe: selection wins, then waiting.
            RoundedRectangle(cornerRadius: 1)
                .fill(selected ? tk.t1 : (status == .waiting ? tk.wait : .clear))
                .frame(width: 2)
                .padding(.vertical, 8)
        }
        .shadow(color: tk.shadowColor, radius: Tokens.shadowRadius, y: Tokens.shadowY)
    }

    private func statusDot(_ status: Status) -> some View {
        Group {
            switch status {
            case .running:
                Circle().fill(tk.run)
                    .shadow(color: tk.run.opacity(0.55), radius: 2.5)
            case .waiting:
                Circle().fill(tk.wait)
            case .idle:
                Circle().fill(tk.idle)
                    .overlay(Circle().strokeBorder(tk.bd2))
            }
        }
        .frame(width: 6, height: 6)
    }

    private func statusLabel(_ status: Status) -> String {
        switch status {
        case .running: return "running"
        case .waiting: return "waiting"
        case .idle: return "idle"
        }
    }

    private func statusLabelColor(_ status: Status) -> Color {
        switch status {
        case .running: return tk.run.opacity(0.8)
        case .waiting: return tk.wait
        case .idle: return tk.t4
        }
    }
```

- [ ] **Step 4: Recent rows** — replace the `recentList` row body (structure stays: enumerated ForEach, Relaunch button, selection background):

```swift
    private var recentList: some View {
        let items = model.visibleRecents()
        let now = Int64(Date().timeIntervalSince1970)
        return List {
            ForEach(Array(items.enumerated()), id: \.element.name) { idx, r in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("↻").font(mono(11)).foregroundStyle(tk.t4)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(r.name).font(mono(13)).foregroundStyle(tk.t3)
                                .lineLimit(1)
                            Spacer()
                            if let stopped = r.stoppedAt {
                                Text(humanizeAge(now - stopped))
                                    .font(mono(11)).foregroundStyle(tk.t4)
                            }
                        }
                        HStack(spacing: 6) {
                            Text(String(r.agent.split(separator: " ").first ?? ""))
                                .font(mono(11)).foregroundStyle(tk.t4)
                            Text(collapseHome(r.dir))
                                .font(.system(size: 11)).foregroundStyle(tk.t4)
                                .lineLimit(1).truncationMode(.head)
                        }
                    }
                    Button("Relaunch") { Task { await model.relaunchRecent(r) } }
                        .buttonStyle(.borderless)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(model.recentSelected == idx ? tk.surf2 : Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(tk.surface)
    }
```

(the `↻` glyph now marks every recent row; the resumable hint moves into it — a row WITHOUT `resumeCmd` relaunches fresh, so keep the distinction: wrap the glyph in `.help(r.resumeCmd != nil ? "relaunch resumes the conversation" : "relaunch starts fresh")` and dim it to `tk.surf4` when `resumeCmd == nil`).

- [ ] **Step 5: Build + full suite**

Run: `swift build && swift test`
Expected: green (visual-only change; failures = stray edit).

- [ ] **Step 6: Visual smoke**

```bash
swift run covey
```

1. Active: cards with border/shadow; selected card lighter with `t1` stripe; waiting card with amber stripe and amber name; running dot glows.
2. Numbers match `1`–`9` jumps (`selectByNumber`); filter narrows and renumbers.
3. Row 2: agent + branch + right-aligned `+N`/`−N`; returnable badge replaces it when the worktree is gone.
4. Project headers: CAPS name, note counts, `running/total` on the right.
5. Prompt pills still glass and clickable inside the card.
6. Drag reorder still works; context menu (Rename/Kill) still works.
7. Recent: `↻` rows with agent + collapsed path + age on the right; Relaunch works; selection highlight `surf2`.
8. Light theme (theme toggle): everything readable, light token set applied.

- [ ] **Step 7: Hand the commit to the user**

```bash
git add Sources/covey/Views/SessionListView.swift
git commit -m "feat(covey): card session list on design tokens (amux variant A)"
```
