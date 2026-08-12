# Covey

**Covey** is a native macOS application for managing multiple parallel sessions of AI coding agents (Claude Code and similar CLI agents) at once.

 It is a rewritten from scratch in pure Swift counterpart of Rust application `agents_multiplexer`
(`amux-desktop` + `amux-core`), without tmux and without Electron/WebView — only AppKit/SwiftUI
and its own daemon managing processes directly.

## Project goal

When several agent sessions are running in parallel (each is a long-lived process
in its own PTY, often bound to its own git-worktree), you need a single center from which
you can see them all: what is happening in each session, who is waiting for a response, who is still working, what
changes appeared in the code. Covey is such a center of observation and management: the user
switches between sessions, reads their output and git-diffs, works with issues and monitors
Claude's usage limits.

## Architecture

The application consists of two parts in a client/server model:

- **`coveyd`** is a background daemon (launched as a `launchd` LaunchAgent). It owns all
  PTY and child processes of agents, stores their scrollback buffers, determines the status
  of the session by the screen content, and survives a GUI restart.
- **`covey`** is a SwiftUI application (a thin client). It connects to the daemon via a Unix socket,
  subscribes to session events, renders the terminal via SwiftTerm, and stores
  user settings and unfinished issue drafts.

## Functions

- **Parallel agent sessions** — create, rename, and stop sessions;
  a list of active and recent sessions, grouped by project.
- **Live Terminal** — rendering via SwiftTerm (display only, no startup
  processes on the UI side), with scrollback and a history mode indicator.
- **Auto-detection of session status** — running / waiting / idle by analyzing the output
  and detecting the prompt of the agent waiting for input.
- **Git integration** — displaying the branch, change statistics (added/removed),
  working with git worktrees when creating sessions.
- **Worktree sessions** — creating a session in a separate git worktree, with the subsequent
  option to delete the branch when the session is completed.
- **Issue-browser** - view, create and edit issue right inside the app
  (list, detail view, composer); unfinished drafts are saved between sessions.
- **Claude usage limits** - read OAuth token from Keychain, poll
  `GET /api/oauth/usage` and display usage windows (5h / 7d) as a chip
  in the terminal bar header.
- **System notifications** - alerts about session status changes, even when
  the application is in the foreground.
- **Flexible layout** - native `NSSplitView` with drag-and-drop dividers
  (session list / terminal / inspector), saved between launches.
- **Keyboard control** - native ⌘-combinations and menu bar as a basis,
 plus an optional vim mode with leader-sequences and a vim-like
 text editor (normal/insert/visual modes).
- **State persistence** - UI settings, session order, themes and issue drafts
  are saved in `~/.covey/state.json`.
