# Covey

**Covey** is a native macOS control center for running and supervising multiple AI coding agents in parallel. Each agent lives in its own long-running PTY, optionally in a dedicated Git worktree, while one SwiftUI application exposes the terminals, session state, repository context, GitHub issues, usage limits, and agent traces.

Covey is a from-scratch Swift counterpart to the Rust `agents_multiplexer` project (`amux-desktop` + `amux-core`). It does not use tmux, Electron, or a WebView: the application is AppKit/SwiftUI, terminal emulation is provided by SwiftTerm, and a local daemon owns the child processes directly.

## Status and requirements

Covey is currently a source-built development project rather than a packaged release.

- macOS 26 or newer
- Xcode/Swift toolchain with Swift 6.3 support
- `git`
- at least one agent CLI on `PATH` (`claude` and `codex` are the built-in presets)
- `gh`, authenticated for the repository, to use the GitHub Issues inspector
- XcodeGen to build the `.app` bundle with `make app`

Other CLI agents can be added as presets or entered as a custom command. Covey launches the executable and its flags directly; it does not interpret shell syntax in the custom-agent field.

## Features

- **Parallel sessions** — create, rename, restart, stop, reorder, filter, and relaunch recent sessions grouped by project.
- **Daemon-owned PTYs** — `coveyd` owns agent processes, terminal state, and scrollback, so closing or restarting the GUI does not terminate live sessions.
- **Embedded terminal** — SwiftTerm rendering with attach backfill, normal-buffer history scrolling, TUI-aware mouse/trackpad routing, resize protection, and Finder file drops as shell-quoted paths.
- **Agent and repository signals** — running/waiting/idle inference, the last observed Claude/Codex model, current branch, and added/removed line counts.
- **Git worktrees** — open existing branches or create new branches in linked worktrees; remove worktrees, delete safe branches, promote a worktree to the repository root, and clean up merged branches.
- **Terminal splits** — add a vertical or horizontal companion shell to the selected agent session and move keyboard focus between panes.
- **Agent traces** — normalize Claude Code transcripts and Codex rollouts into one event stream with turns, tool calls/results, edits, token usage, model/effort metadata, and nested-agent filtering. Normalized traces are retained locally for seven days.
- **GitHub Issues** — browse, search, create, edit, close, reopen, and delete issues through `gh`; issue drafts are persisted per project, and issues can seed session names and branches.
- **Provider profiles** — Claude Code can use the normal Anthropic login or Claude-compatible providers. Anthropic and GLM are built in; additional profiles can be defined in `~/.covey/config.json`, with secrets stored in Keychain.
- **Usage monitoring** — Claude OAuth windows, Codex ChatGPT limits via `codex app-server`, and the GLM token window. Claude and Codex crossings at 80% generate deduplicated system notifications when Covey runs as an app bundle.
- **Keyboard-first UI** — command palette, native menu shortcuts, optional vim-style workspace navigation, and a Vim-like issue text editor with normal/insert/visual modes.
- **Persistent workspace** — theme, panel visibility and sizes, project/session order, recent sessions, provider toggles, issue bindings, and drafts are stored in `~/.covey/state.json`.

## Architecture

Covey uses a local client/server design:

| Component | Responsibility |
| --- | --- |
| `CoveyKit` | Shared models, NDJSON protocol, IPC client, creation rules, persisted schemas, and provider profiles |
| `CoveydCore` | PTY runtime, session registry, IPC server, Git operations, status/model/trace monitors, and trace storage |
| `coveyd` | Single-instance daemon listening on `~/.covey/coveyd.sock` |
| `covey` | SwiftUI/AppKit client, terminal views, command routing, settings, usage services, and GitHub Issues UI |

The GUI probes the Unix socket and starts the sibling `coveyd` executable on demand when no daemon is accepting connections. The daemon is not installed as a `launchd` agent. It survives GUI restarts, but a daemon restart necessarily loses its live child processes; their saved metadata is surfaced to the GUI as relaunchable recent sessions.

```text
Covey.app / covey
        │  NDJSON requests, responses, and events
        ▼
~/.covey/coveyd.sock
        │
        ▼
      coveyd ── SessionRegistry ── PTYSessionRuntime ── agent CLI
        │              │
        │              ├── screen/status + Git/model monitoring
        │              └── scrollback and attach replay
        └── Claude/Codex transcript adapters ── normalized trace store
```

The daemon is the source of truth for live sessions. The application mutates its session list only after daemon responses and events confirm a change.

## Build and run

For the SwiftPM development loop:

```bash
swift build
swift test
swift run --skip-build covey
```

Building first ensures that both sibling executables exist; `covey` expects to find `coveyd` next to itself. A bare SwiftPM executable can run the UI, but macOS notifications require an application bundle.

To build the release app bundle:

```bash
make app
open .build/xcode/Build/Products/Release/Covey.app
```

`make app` regenerates the ignored Xcode project from `project.yml`, embeds and signs `coveyd`, and builds `Covey.app`. `make install` additionally replaces `/Applications/Covey.app`.

## Configuration and local data

Optional user configuration is read from `~/.covey/config.json`. For example:

```json
{
  "defaultAgent": "claude",
  "agentPresets": ["claude", "codex", "gemini"],
  "defaultProvider": "glm"
}
```

The main local files are:

| Path | Contents |
| --- | --- |
| `~/.covey/config.json` | Agent presets and Claude-compatible provider profiles |
| `~/.covey/state.json` | GUI preferences, projects, recents, ordering, usage cache, and issue drafts |
| `~/.covey/registry.json` | Daemon metadata used to surface sessions lost with a previous daemon process |
| `~/.covey/coveyd.sock` | Local Unix socket, created with mode `0600` |
| `~/.covey/traces/` | Normalized per-session trace events and source cursors |

Provider secrets are not written to these JSON files. Covey stores configured provider keys in macOS Keychain; Claude usage reads Claude Code's existing OAuth credential file or Keychain item.

## Project layout

```text
Sources/CoveyKit/       shared protocol and domain logic
Sources/CoveydCore/     daemon implementation
Sources/coveyd/         daemon entry point
Sources/covey/          macOS application and views
Tests/CoveyKitTests/    shared logic and IPC client tests
Tests/CoveydCoreTests/  daemon, PTY, monitoring, and end-to-end tests
Tests/CoveyAppTests/    UI-model and presentation logic tests
```

SwiftPM is the source of truth for targets and tests. `project.yml` mirrors the application and daemon targets for the signed `.app` bundle.
