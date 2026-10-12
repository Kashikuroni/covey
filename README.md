# Covey

**Covey** is a native macOS control center for running and supervising multiple AI coding agents in parallel. Each agent lives in its own long-running PTY, optionally in a dedicated Git worktree, while one SwiftUI application exposes the terminals, session state, repository context, GitHub issues, usage limits, and agent traces.

Covey is a from-scratch Swift counterpart to the Rust `agents_multiplexer` project (`amux-desktop` + `amux-core`). The application is AppKit/SwiftUI, terminal emulation is provided by SwiftTerm, and a local daemon owns the child processes directly. A sandboxed WKWebView renders read-only project documents with bundled offline Markdown and syntax-highlighting assets.

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
- **Project documents** — open Markdown specifications and plans beside the agent with an outline, local search, history, source view, and live file refresh. Other UTF-8 files have a plain-text preview; binary files show metadata.
- **Agent traces** — normalize Claude Code transcripts and Codex rollouts into one event stream with turns, tool calls/results, edits, token usage, model/effort metadata, and nested-agent filtering. Normalized traces are retained locally for seven days.
- **GitHub Issues** — browse, search, create, edit, close, reopen, and delete issues through `gh`; issue drafts are persisted per project, and issues can seed session names and branches.
- **Provider profiles** — Claude Code can use the normal Anthropic login or Claude-compatible providers. Anthropic is built in; additional profiles can be defined in `~/.covey/config.json`, with secrets stored in Keychain.
- **Usage monitoring** — Claude OAuth windows and Codex ChatGPT limits via `codex app-server`. Claude and Codex crossings at 80% generate deduplicated system notifications when Covey runs as an app bundle. Every poll, RPC error, and parse failure is recorded to a local diagnostics log, searchable in-app via Command-P › Search App Logs.
- **Keyboard-first UI** — command palette, native menu shortcuts, optional vim-style workspace navigation, and a Vim-like issue text editor with normal/insert/visual modes.
- **Persistent workspace** — theme, panel visibility and sizes, project/session order, recent sessions, provider toggles, issue bindings, and drafts are stored in `~/.covey/state.json`.

## Architecture

### Reading project documents

Use **Command-P → Open Project Document**. The picker starts with Markdown files;
turn off **Markdown only** to browse other project files. Search matches relative
paths, recent documents appear first, and arrow keys select a file. An exact path
can open a file excluded from the picker.

The document pane stays bound to the originating session's actual working tree.
Changing the selected agent does not redirect an existing pane to another root.
Local links and images stay inside that project; HTTP/HTTPS links open in the
browser. Documents are read only, refresh after filesystem changes, and restore
the reading position. Text previews are limited to 4 MB. Markdown supports
headings, tables, nested lists, task lists, fenced code, and reference links.
Raw HTML and project scripts are not executed.

With Documents focused, **Command-F** searches the document, **Command-W** closes
the pane, **Command-C** copies the native selection, and **Control-H/L** moves
between workspace zones. Opening and closing documents preserves agent PTYs.

The gear panel, Covey → Settings, Command-comma and the Settings palette command
open the same settings. Switches apply immediately; document custom rules use
Apply rules and Revert.

**Settings → Documents** manages independent picker rules; `.gitignore`
never limits document access. Global rules can be overridden per project, shared
by its worktrees. Automatic presets exclude VCS internals, Rust `target`, Node
dependency/cache folders, Python environments/caches, and Next/Nuxt output only
when those frameworks are detected. Swift/Xcode projects exclude `.build`,
`.swiftpm`, `DerivedData`, `build`, `xcuserdata`, `*.xcuserstate`, and
`*.xcuserdatad`, preserving project/workspace configuration. Settings shows
each preset's patterns and effective status, plus up to 200 actual excluded
paths with the rule and scope responsible. Excluded folders stand for all
their contents, which are not scanned or counted. Other build/report folders such as `dist`, `out`,
`coverage`, and `storybook-static` are optional and initially visible. `docs`,
`specs`, `plans`, `.claude`, `.codex`, and `.github` remain visible by default.

Custom rules use one glob per line: `*`, `**`, `?`, character classes, backslash
escaping, `#` comments, leading `/` for the root, trailing `/` for directories,
and `!` to include again. The last matching rule wins; an excluded parent must
be included before a child can be included. Invalid rules block Apply. Reset
presets preserves custom rules, while Inherit clears project overrides. Changes
apply immediately for switches and through Apply rules for custom text;
Revert or closing settings discards unapplied text. Rules
affect browsing/search only: exact paths, local links, and open-file refresh still
work. Workspace state stores paths, position, pane width, and up to 30 recent
paths per working root, without storing document content.

### Client and daemon

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
  "defaultProvider": "anthropic"
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
| `~/Library/Logs/Covey/` | NDJSON diagnostics logs (`usage.log` for usage polling, rotated at 1 MB; `pane-layout.log`) |

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
