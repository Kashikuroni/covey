# covey — Handoff Spec (Swift / macOS native port)

> This document is the build brief for a fresh agent. It specifies **behavior and
> data**, not pixels. Build idiomatic macOS; do not clone the Dioxus UI pixel-for-pixel.
> When exact behavior is ambiguous, the Rust source listed in §10 is the ground truth.

---

## 1. Mission & constraints

`covey` is a native macOS app for supervising a flock of parallel AI coding-agent
sessions (Claude Code and similar CLI agents). Each session is a long-running agent
process attached to a PTY; the user watches them, switches between them, reads their
git diffs and notes, and tracks Claude usage limits.

It is a from-scratch rewrite of the existing Rust app (`agents_multiplexer`, crates
`amux-desktop` + `amux-core`). The rewrite drops tmux entirely.

**Hard constraints**

- **Pure Swift, macOS-only.** No Rust, no FFI to the old core, no Electron/WebView.
- **No tmux.** Session/PTY lifecycle is owned by a Swift daemon (see §4).
- **Terminal via SwiftTerm** (https://github.com/migueldeicaza/SwiftTerm), used in
  render-only mode (`TerminalView`, **not** `LocalProcessTerminalView`).
- **Native look.** Use AppKit/SwiftUI idioms (`NSSplitView`, `List`, sheets, menu bar).
  Preserve *function and behavior*, reinterpret *layout and chrome* natively.

**Scope of THIS phase**

- App shell (window chrome, top bar, status bar, resizable split).
- Session list (Active / Recent) + selection.
- Working terminal on SwiftTerm, fed by the daemon.
- Persistence (`state.toml` — UI prefs, order, notes, recents).
- Claude usage limits (5h / 7d windows).

**Out of scope this phase** (later specs): git graph, stage panel, commit modal,
merge modal, working-diff inspector, command palette, all secondary modals
(Kill/Rename/Promote/DeleteBranch/Cleanup/Issue beyond what session CRUD needs).

**Locked decisions**

- Name: GUI binary `covey`, daemon `coveyd`, bundle id `com.<owner>.covey`,
  config dir `~/.covey/`.
- Keyboard: **native base** (menu bar + standard ⌘ shortcuts) with an **optional**
  vim/leader-chord mode (off by default).
- Session list tabs: **Active / Recent only** (the old "Tmux" foreign-session tab is removed).
- Session survival across GUI restart: **daemon holds the PTYs** (client/server model).

---

## 2. Target architecture

Three units, mirroring tmux's client/server split — but the "server" is our daemon
and the "client" is the SwiftUI GUI.

```
┌─────────────────────────┐         Unix domain socket          ┌──────────────────────────┐
│  covey (SwiftUI GUI)     │  ~/.covey/coveyd.sock (NDJSON)      │  coveyd (daemon)          │
│                          │ ─────── requests ──────────────▶   │                           │
│  • window / split        │ ◀────── responses + events ──────   │  • PTY pool (forkpty)     │
│  • session list          │                                     │  • child agent processes  │
│  • SwiftTerm render-only │  ◀══ output byte stream (per attach)│  • scrollback buffers     │
│  • inspector / topbar    │  ══▶ input bytes / resize           │  • status inference       │
│  • state.toml owner      │                                     │  • session registry       │
│  • usage limits poll     │                                     │  • survives GUI restart   │
└─────────────────────────┘                                     └──────────────────────────┘
```

- **`coveyd`** replaces `amux-core::tmux`. It owns every PTY and agent child process,
  keeps a bounded scrollback per session, infers status, and persists a session
  registry so it can restore itself after its own restart. It launches as a
  `launchd` LaunchAgent (`~/Library/LaunchAgents/com.<owner>.coveyd.plist`) and is
  auto-started by the GUI if not already running.
- **`covey`** is a thin, stateless-about-sessions client. It connects to the socket,
  subscribes to session events, attaches to the selected session's output stream, and
  feeds bytes into a SwiftTerm `TerminalView`. It owns only *UI* state and `state.toml`.
- **SwiftTerm** does VT parsing + rendering + scrollback display only. It never spawns
  a process. Bytes in from daemon → `terminal.feed(...)`; user keystrokes → daemon.

### Rust module → Swift component map

| Rust (ground truth)                  | Swift target                     | Notes |
|--------------------------------------|----------------------------------|-------|
| `amux-core::tmux`                    | `coveyd` PTY pool + IPC          | Reimplement; tmux semantics → owned child processes |
| `amux-core::status`                  | `coveyd` status inference        | Port prompt detection + content-hash diff |
| `amux-core::state`                   | `covey` `StateStore` (Codable)   | Same `state.toml` schema (§8) |
| `amux-core::usage`                   | `covey` `UsageService`           | Keychain token + `GET /api/oauth/usage` |
| `amux-core::create`                  | `coveyd` agent-command resolver  | `resolve_agent_command_for_tmux` → spawn argv |
| `amux-core::note`                    | `covey` note utils               | Markdown checkbox counts |
| `amux-core::timeutil`                | `covey` time utils               | `humanize_age` |
| `amux-desktop::state` (AppState)     | `covey` `AppModel` (@Observable) | Signals → observable properties (§7) |
| `amux-desktop::data` (UiSession)     | `covey` `SessionVM`              | View-model + ordering (§3) |
| `amux-desktop::ui::mod/topbar/...`   | SwiftUI views                    | Behavior per §6 |
| `amux-desktop::ui::xterm`            | `TerminalController` + SwiftTerm | Render-only wiring (§5) |
| `amux-desktop::vt` (TermTheme)       | `TerminalTheme`                  | ANSI palette → SwiftTerm colors (§5) |

---

## 3. Data model

Translate these to Swift `struct`/`enum` (Codable where persisted). Field semantics
must match the Rust originals; consult §10 for exact parsing.

```swift
// A live session as the daemon knows it (was amux-core::tmux::Session)
struct Session {
    var name: String          // unique id (was cm-* under tmux; now any stable id)
    var dir: String           // launch directory
    var cwd: String           // current working dir (best-effort)
    var agent: String         // agent label, e.g. "claude"
    var created: Int64        // epoch seconds
    var git: GitInfo?         // branch + added/removed (cheap status, see note)
    var worktreeRepo: String? // repo root if this dir is a git worktree
}

struct GitInfo { var branch: String; var added: UInt32; var removed: UInt32 }

enum Status { case running, waiting, idle }   // inferred by daemon, see §4

// UI-facing view-model (was amux-desktop::data::UiSession)
struct SessionVM {
    var session: Session
    var status: Status
    var project: String       // derived grouping key (repo root / dir)
    // + display helpers (age string, note counts)
}

// Usage windows (was amux-core::usage::Usage)
struct Usage { var windows: [UsageWindow] }   // typically 5h + 7d
struct UsageWindow { var name: String; var usedSecs: Int64; var limitSecs: Int64 }
```

Status inference (§4) and the `state.toml` schema (§8) are detailed separately.

---

## 4. Session lifecycle without tmux (`coveyd`)

This is the core new work. tmux gave us: a session registry, attach/detach, pane
capture, resize, and survival across GUI restarts. The daemon must provide all of it.

### PTY pool
- Each session = one child process (the resolved agent argv, e.g. `claude` or a shell)
  spawned via `forkpty` (Darwin) into its own PTY. Slave → child stdio; master → daemon.
- Daemon pumps master output into:
  1. a bounded **scrollback ring buffer** (so a late-attaching GUI can backfill), and
  2. any attached client's output stream.
- Daemon writes client input bytes to the master, and issues `TIOCSWINSZ` (cols×rows)
  on resize.

### Status inference (port of `amux-core::status`)
- Daemon periodically inspects recent PTY output. Port `parse_prompt` (detect an
  agent prompt awaiting user input) + `content_hash` (detect "screen changed" =
  activity). Map to: **Running** (content changing), **Waiting** (prompt detected,
  no change), **Idle** (no change, no prompt). Emit `StatusChanged` events.

### IPC protocol (Unix socket, newline-delimited JSON)
Socket: `~/.covey/coveyd.sock`. One connection carries request/response **and** async
events; output streams are framed events tagged by session.

Client → daemon requests:
- `list` → `{ sessions: [Session], status: {name: Status} }`
- `create { dir, agent, argv?, name? }` → `{ session }`
- `kill { name }` → `{ ok }`
- `rename { name, newName }` → `{ ok }`
- `attach { name, sinceSeq? }` → backfills scrollback, then streams `output` events
- `detach { name }`
- `input { name, bytesB64 }`
- `resize { name, cols, rows }`

Daemon → client events:
- `output { name, seq, bytesB64 }`
- `sessionAdded { session }` / `sessionRemoved { name }` / `statusChanged { name, status }`
- `exited { name, code }`

(Base64 for byte payloads keeps the JSON framing clean; a binary length-prefixed
frame is an acceptable alternative if perf demands it — document whichever you pick.)

### Restart / restore semantics
- **GUI restart:** sessions keep running in the daemon. On launch the GUI auto-starts
  `coveyd` if absent, then `list` + re-`attach` to the previously selected session.
- **Daemon restart / reboot:** running child processes do **not** survive (we are not
  re-parenting live PTYs). The daemon persists a session *registry* (name, dir, agent,
  argv) and on restart **respawns** those sessions fresh. The transcript before the
  crash is lost; this matches the "respawn from metadata" expectation. (A future
  upgrade could re-parent via a detached supervisor, but that is out of scope.)

---

## 5. Terminal integration (SwiftTerm, render-only)

- Use `SwiftTerm.TerminalView` embedded in SwiftUI via `NSViewRepresentable`.
  Do **not** use `LocalProcessTerminalView` — the daemon owns the process.
- Wiring (`TerminalController`):
  - On session select: `attach` to daemon; feed backfilled scrollback then live
    `output` events into `terminalView.feed(byteArray:)`.
  - `TerminalViewDelegate.send(...)` → daemon `input`.
  - `sizeChanged(cols,rows)` → daemon `resize`. Daemon is the source of truth for the
    PTY winsize; SwiftTerm's own grid follows the view bounds.
  - On session switch, tear down the old attach and start a fresh `TerminalView`
    (key-based remount, like the Dioxus version).
- **Scrollback / history mode:** SwiftTerm owns scrollback natively. Preserve the old
  behavior where scrolling up freezes a "history" indicator in the status bar
  (`term_history` flag) — wire it to SwiftTerm's scroll position.
- **Theme:** port `amux-desktop::vt::TermTheme` (dark + light, 16-color ANSI palette +
  bg/fg/cursor) into a `TerminalTheme` that sets SwiftTerm's `installColors` / color
  properties. Dark default: bg `#1C1917`, fg `#FAF7F2`, bright-orange cursor.

---

## 6. UI surfaces (behavioral, native)

Window: native macOS, traffic lights overlaid on a transparent/full-size-content
title bar (the old app used the Warp style). Implement with native window styling, not
a faux chrome.

Layout (native `NSSplitView`/`HSplitView`, all dividers draggable, widths persisted):

```
┌───────────────────────────────────────────────────────────┐
│ Topbar: identity · session counts · view/theme toggle · clock│
├──────────────┬──────────────────────────────┬──────────────┤
│ Session list │ Terminal pane                 │ Inspector     │
│ Active/Recent│  header + SwiftTerm view       │ (later phase) │
│ + filter     │                                │               │
├──────────────┴──────────────────────────────┴──────────────┤
│ Status bar: key hints · context (history mode, focus, etc.) │
└───────────────────────────────────────────────────────────┘
```

- **Topbar** (port of `topbar.rs`): app name, counts (total / running / waiting),
  theme toggle, clock. View switcher exists but Git view is a later phase — keep the
  control, stub the target.
- **Session list** (port of `session_list.rs`, minus the Tmux tab):
  - **Active** tab: live sessions grouped by project. Status glyph per row
    (running=orange, waiting=amber, idle=gray). Selection drives the terminal.
  - **Recent** tab: stopped sessions from `state.toml` recents (newest first, max 20),
    re-launchable.
  - Inline filter bar (fuzzy filter over session names).
  - Manual ordering within a project is persisted (`order`, `project_order`).
- **Terminal pane** (port of `terminal.rs`): session header (name, dir/branch, agent)
  + the SwiftTerm view + the Claude usage chip (see §9). Capture view size → cols/rows.
- **Inspector**: present a placeholder/empty native panel this phase (Note/Diff/etc.
  are later). Keep the split + width persistence (`sb_width`) working.
- **Status bar** (port of `statusbar.rs`): contextual key hints + state indicators
  (history-mode, focused pane).

Modals needed this phase, as native **sheets**: **New session** (directory picker via
`NSOpenPanel`, agent selector), **Kill** (confirm), **Rename**. Everything else later.

---

## 7. State machine (`AppModel`)

Port `amux-desktop::state::AppState`. Dioxus `Signal<T>` → properties on an
`@Observable` (or `ObservableObject`) `AppModel`; persisted ones write through to
`StateStore`. Keep these enums:

- `View`: `.standard`, `.git` (git is stubbed this phase)
- `Theme`: `.dark`, `.light`
- `Focus`: `.sessions`, `.terminal`, `.inspector`
- `Mode`: `.normal`, `.search`, `.insert` (only relevant once vim mode / filter exist)
- `SlTab`: `.active`, `.recent`  (note: **no** `.tmux`)
- `Modal`: `.new`, `.kill`, `.rename`  (this phase)

Selected non-persisted state: `selectedSession`, `sessions`, `statusByName`,
`previewSize (cols,rows)`, `focus`, `filter`/`filterOn`, `historyMode`, `toast`.
Persisted state: see §8.

**Keyboard:** native base — wire a real macOS **menu bar** (File/Session/View/Window)
with standard ⌘ shortcuts (⌘N new, ⌘W kill/close, ⌘1/2/3 focus panes, ⌘F filter, etc.).
Implement an **optional vim/leader mode** (off by default, toggle in settings) that
layers the leader-chord tree from `keys.rs` on top; port that only after the native
layer works.

---

## 8. Persistence (`state.toml`)

Owned by the GUI, at `~/.covey/state.toml` (the old app used `~/.agent-multiplexer/`).
Keep the schema below (port of `amux-core::state::State`) so the format is stable and
documented. Use a TOML library (e.g. TOMLKit) with Codable structs.

```toml
split_pct      = 38          # left-pane width (% of workspace)
order          = []          # session order within a project
project_order  = []          # project ordering
theme          = "dark"      # "dark" | "light"
font_scale     = 100         # UI font scale %
sb_width       = 360         # inspector width px
show_sessions  = true
show_footer    = true
show_header    = true

[project_names]   # path -> display name
[project_notes]   # path -> markdown
[notes]           # session_name -> markdown (task lists)
[drafts]          # session_name -> in-progress reply text
[sessions]        # name -> PersistedSession (to restore/respawn on boot)
recents = []      # [RecentSession] stopped sessions, newest first, max 20
```

Save-on-change (debounced). Note: the *session registry the daemon respawns from* (§4)
may live daemon-side; keep the GUI's `[sessions]`/`recents` as the user-facing record.
Reconcile ownership explicitly when you implement — document the chosen split.

---

## 9. Claude usage limits

Port `amux-core::usage`. (Reference: the existing app reads the Claude Code OAuth
token from the macOS Keychain and calls `GET /api/oauth/usage`.)

- `UsageService`: read the keychain token, `GET /api/oauth/usage` (~60s poll), parse
  the 5h and 7d subscription windows into `[UsageWindow]`, plus a plan badge string
  (e.g. "Max 5×"). Surface fetch errors without crashing.
- Display: a compact chip in the terminal-pane header for Claude sessions only (used vs
  limit per window). Only shown when the selected session's agent is Claude.

---

## 10. Ground-truth index

Source of truth is the `agents_multiplexer` repo, branch **`feat/desktop-swift`**
(paths relative to repo root). Read these when behavior is ambiguous:

| Behavior | File |
|----------|------|
| Session ops, capture, resize, I/O (replaced by daemon) | `crates/amux-core/src/tmux.rs` |
| Status inference (prompt detect, content hash) | `crates/amux-core/src/status.rs` |
| `state.toml` schema + load/save + recents | `crates/amux-core/src/state.rs` |
| Usage limits (keychain + endpoint) | `crates/amux-core/src/usage.rs` |
| Agent command resolution | `crates/amux-core/src/create.rs` |
| Note checkbox counts / humanized time | `crates/amux-core/src/note.rs`, `timeutil.rs` |
| App state / signals | `crates/amux-desktop/src/state.rs` |
| Session view-model, polling, ordering | `crates/amux-desktop/src/data.rs` |
| Terminal bridge (PTY + render) — the part we re-split | `crates/amux-desktop/src/ui/xterm.rs`, `ui/terminal.rs` |
| Session list behavior | `crates/amux-desktop/src/ui/session_list.rs` |
| Topbar / statusbar | `crates/amux-desktop/src/ui/topbar.rs`, `ui/statusbar.rs` |
| Terminal theme / ANSI palette | `crates/amux-desktop/src/vt.rs` |
| Theme tokens / colors | `crates/amux-desktop/assets/style.css` |
| Keyboard model (for the optional vim layer, later) | `crates/amux-desktop/src/ui/keys.rs` |

---

## 11. Suggested Swift project layout

```
covey/
  Package.swift            # SwiftPM workspace, or an .xcodeproj
  Sources/
    coveyd/                # daemon executable target
      PTYPool.swift        # forkpty, child processes, scrollback
      StatusInferer.swift  # port of status.rs
      IPCServer.swift      # unix socket, NDJSON request/response + events
      SessionRegistry.swift
    CoveyKit/              # shared models + IPC client (library)
      Models.swift         # Session, Status, Usage, State (Codable)
      IPCClient.swift
      StateStore.swift     # state.toml read/write
      UsageService.swift
    Covey/                 # SwiftUI app target
      App.swift            # window, menu bar
      AppModel.swift       # observable state machine
      Views/               # Topbar, SessionList, TerminalPane, StatusBar, sheets
      Terminal/            # TerminalController + SwiftTerm NSViewRepresentable
      TerminalTheme.swift
  docs/
    HANDOFF.md             # this file
```

Dependencies: **SwiftTerm** (terminal), a **TOML** lib (e.g. TOMLKit). Minimum macOS
target: pick the lowest that SwiftTerm + your APIs support (likely macOS 13+).

---

## 12. Definition of done (this phase)

1. `coveyd` runs as a LaunchAgent, owns PTYs, exposes the §4 IPC, infers status,
   survives GUI restart, respawns its registry on its own restart.
2. `covey` connects, lists Active/Recent sessions, creates/kills/renames sessions.
3. Selecting a session shows a live, interactive terminal (SwiftTerm) with correct
   resize, scrollback, and history-mode indicator.
4. `state.toml` round-trips all §8 fields; split widths, order, theme, notes persist.
5. Claude usage chip shows 5h/7d windows for Claude sessions.
6. Native menu bar + standard shortcuts work; vim mode toggle exists (may be stubbed).
