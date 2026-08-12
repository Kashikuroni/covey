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
    var canMoveSessionUp = false
    var canMoveSessionDown = false
}

enum CommandRules {
    static func availability(
        for command: AppCommand,
        context: CommandContext
    ) -> CommandAvailability {
        switch command {
        case .newSession, .recentSessions, .filterSessions,
             .toggleSessionsPanel, .toggleInspector, .toggleAgentTrace,
             .toggleStatusBar, .toggleTopBar, .toggleTheme, .cycleUsagePlacement,
             .showLimitsDetail, .focusSessionList, .showKeyboardHelp,
             .addProject, .settings:
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
            return context.hasSelectedSession
                ? .enabled : .disabled(reason: "No session selected")

        case .closeTerminalSplit, .focusTerminalSplit:
            guard context.hasSelectedSession else {
                return .disabled(reason: "No session selected")
            }
            return context.hasTerminalSplit
                ? .enabled : .disabled(reason: "No terminal split")

        case .focusAgent:
            return context.hasSelectedSession
                ? .enabled : .disabled(reason: "No session selected")

        case .focusIssues, .focusTrace:
            return context.inspectorShown
                ? .enabled : .disabled(reason: "Inspector is hidden")
        }
    }
}
