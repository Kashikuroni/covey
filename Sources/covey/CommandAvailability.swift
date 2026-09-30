enum CommandAvailability: Equatable {
    case enabled
    case disabled(reason: String)

    var isEnabled: Bool { self == .enabled }
}

struct CommandContext: Equatable {
    var hasSelectedSession = false
    var hasProject = false
    var selectedHasGit = false
    var selectedIsWorktree = false
    var selectedBranch: String?
    var selectedBranchProtected = false
    var selectedCanReturnToRoot = false
    var hasTerminalSplit = false
    var inspectorShown = false
    var hasClaudeSessions = false
    var visibleSessionCount = 0
    var canMoveSessionUp = false
    var canMoveSessionDown = false
    var terminalFocused = false
    var agentPaneCount = 0
    /// Cmd+W сейчас что-то закроет: фокус на колонке или agent-панель в дереве.
    var canCloseFocusedPane = false
    /// Review covers the sessions workspace (`AppModel.windowMode == .review`).
    var reviewOpen = false
    /// A review is alive, so Review can come back without a selected session.
    var hasActiveReview = false
}

enum CommandRules {
    /// What still works while Review covers the workspace: the toggle back and
    /// app-level commands. Nothing here acts on the hidden sessions or changes
    /// the workspace's size (a new size would reach every agent as SIGWINCH).
    static let availableInReview: Set<AppCommand> = [
        .toggleReview, .toggleTheme, .cycleUsagePlacement, .showLimitsDetail,
        .addProject, .settings, .searchLogs,
    ]

    static func availability(
        for command: AppCommand,
        context: CommandContext
    ) -> CommandAvailability {
        if context.reviewOpen, !availableInReview.contains(command) {
            return .disabled(reason: "Review is open")
        }
        return rule(for: command, context: context)
    }

    private static func rule(
        for command: AppCommand,
        context: CommandContext
    ) -> CommandAvailability {
        switch command {
        case .newSession, .recentSessions, .filterSessions,
             .toggleSessionsPanel, .toggleInspector, .toggleAgentTrace,
             .toggleStatusBar, .toggleTopBar, .toggleTheme, .cycleUsagePlacement,
             .showLimitsDetail, .focusSessionList, .showKeyboardHelp,
             .addProject, .settings, .searchLogs:
            return .enabled

        case .selectPreviousSession, .selectNextSession:
            return context.visibleSessionCount > 0
                ? .enabled : .disabled(reason: "No visible sessions")

        case .selectSession1, .selectSession2, .selectSession3,
             .selectSession4, .selectSession5, .selectSession6,
             .selectSession7, .selectSession8, .selectSession9:
            guard let index = command.sessionSelectionIndex,
                  index < context.visibleSessionCount else {
                return .disabled(reason: "Session is not visible")
            }
            return .enabled

        case .newSessionInCurrentProject, .removeProject, .renameProject:
            return context.hasProject
                ? .enabled : .disabled(reason: "No project selected")

        case .killSession, .renameSession, .restartSession:
            return context.hasSelectedSession
                ? .enabled : .disabled(reason: "No session selected")

        case .restartAllClaudeSessions:
            return context.hasClaudeSessions
                ? .enabled : .disabled(reason: "No Claude sessions")

        case .moveSessionUp:
            guard context.hasSelectedSession else {
                return .disabled(reason: "No session selected")
            }
            return context.canMoveSessionUp
                ? .enabled : .disabled(reason: "Session is already first")

        case .moveSessionDown:
            guard context.hasSelectedSession else {
                return .disabled(reason: "No session selected")
            }
            return context.canMoveSessionDown
                ? .enabled : .disabled(reason: "Session is already last")

        case .createGitHubIssue:
            guard context.hasProject else {
                return .disabled(reason: "No project selected")
            }
            return !context.hasSelectedSession || context.selectedHasGit
                ? .enabled : .disabled(reason: "Not a Git repository")

        case .toggleReview:
            if context.reviewOpen || context.hasActiveReview { return .enabled }
            return context.hasSelectedSession
                ? .enabled : .disabled(reason: "No session selected")

        case .openIssueList, .cleanupMergedBranches:
            guard context.hasSelectedSession else {
                return .disabled(reason: "No session selected")
            }
            return context.selectedHasGit
                ? .enabled : .disabled(reason: "Not a Git repository")

        case .promoteWorktree:
            guard context.hasSelectedSession else {
                return .disabled(reason: "No session selected")
            }
            return context.selectedIsWorktree
                ? .enabled : .disabled(reason: "Not a worktree session")

        case .deleteSessionBranch:
            guard context.hasSelectedSession else {
                return .disabled(reason: "No session selected")
            }
            guard !context.selectedIsWorktree else {
                return .disabled(reason: "Cannot delete a worktree session branch")
            }
            guard context.selectedHasGit, context.selectedBranch != nil else {
                return .disabled(reason: "No Git branch")
            }
            return context.selectedBranchProtected
                ? .disabled(reason: "Branch is protected") : .enabled

        case .returnToRepositoryRoot:
            guard context.hasSelectedSession else {
                return .disabled(reason: "No session selected")
            }
            guard context.selectedIsWorktree else {
                return .disabled(reason: "Not a worktree session")
            }
            return context.selectedCanReturnToRoot
                ? .enabled : .disabled(reason: "Worktree is still available")

        case .splitTerminalVertically, .splitTerminalHorizontally:
            guard context.hasSelectedSession else {
                return .disabled(reason: "No session selected")
            }
            return context.agentPaneCount < 8
                ? .enabled : .disabled(reason: "Split limit reached (8 panes)")

        case .closeTerminalSplit:
            guard context.hasSelectedSession else {
                return .disabled(reason: "No session selected")
            }
            guard context.canCloseFocusedPane else {
                return .disabled(reason: "Nothing to close")
            }
            return context.terminalFocused
                ? .enabled : .disabled(reason: "Terminal is not focused")

        case .focusTerminalSplit:
            guard context.hasSelectedSession else {
                return .disabled(reason: "No session selected")
            }
            return context.hasTerminalSplit
                ? .enabled : .disabled(reason: "No terminal split")

        case .toggleViewTerminal:
            return context.hasSelectedSession
                ? .enabled : .disabled(reason: "No session selected")

        case .focusAgent:
            return context.hasSelectedSession
                ? .enabled : .disabled(reason: "No session selected")

        case .focusIssues, .focusTrace:
            return context.inspectorShown
                ? .enabled : .disabled(reason: "Inspector is hidden")
        }
    }
}
