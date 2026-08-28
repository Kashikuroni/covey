import SwiftUI

enum AppCommand: String, CaseIterable, Hashable {
    case newSession, newSessionInCurrentProject, recentSessions, filterSessions
    case selectPreviousSession, selectNextSession
    case selectSession1, selectSession2, selectSession3, selectSession4, selectSession5
    case selectSession6, selectSession7, selectSession8, selectSession9
    case killSession, renameSession, restartSession, restartAllClaudeSessions
    case moveSessionUp, moveSessionDown
    case createGitHubIssue, openIssueList, promoteWorktree, deleteSessionBranch
    case cleanupMergedBranches, returnToRepositoryRoot
    case splitTerminalVertically, splitTerminalHorizontally, closeTerminalSplit
    case toggleSessionsPanel, toggleInspector, toggleAgentTrace
    case toggleStatusBar, toggleTopBar, toggleTheme, cycleUsagePlacement
    case showLimitsDetail, focusSessionList, focusAgent, focusIssues
    case focusTerminalSplit, focusTrace, showKeyboardHelp
    case addProject, removeProject, renameProject, settings
}

extension AppCommand {
    var sessionSelectionIndex: Int? {
        switch self {
        case .selectSession1: return 0
        case .selectSession2: return 1
        case .selectSession3: return 2
        case .selectSession4: return 3
        case .selectSession5: return 4
        case .selectSession6: return 5
        case .selectSession7: return 6
        case .selectSession8: return 7
        case .selectSession9: return 8
        default: return nil
        }
    }
}

enum CommandCategory: Int, CaseIterable, Hashable {
    case session, git, terminal, view, project, app

    var title: String {
        switch self {
        case .session: return "Session"
        case .git: return "Git"
        case .terminal: return "Terminal"
        case .view: return "View"
        case .project: return "Project"
        case .app: return "App"
        }
    }

    var aliases: [String] {
        switch self {
        case .session: return ["session", "sessions", "сессия", "сессии"]
        case .git: return ["git", "github", "гит", "гитхаб"]
        case .terminal: return ["terminal", "shell", "терминал", "оболочка"]
        case .view: return ["view", "ui", "interface", "вид", "интерфейс"]
        case .project: return ["project", "repository", "проект", "репозиторий"]
        case .app: return ["app", "application", "приложение"]
        }
    }
}

struct CommandShortcut: Equatable {
    let key: Character
    let modifiers: EventModifiers
    let display: String
}

struct CommandDescriptor: Identifiable, Equatable {
    let id: AppCommand
    let title: String
    let category: CommandCategory
    let aliases: [String]
    let shortcut: CommandShortcut?
}

enum CommandCatalog {
    private static let command = EventModifiers.command
    private static let commandShift: EventModifiers = [.command, .shift]

    private static func descriptor(
        _ id: AppCommand,
        _ title: String,
        _ category: CommandCategory,
        _ aliases: [String],
        _ shortcut: CommandShortcut? = nil
    ) -> CommandDescriptor {
        CommandDescriptor(id: id, title: title, category: category,
                          aliases: aliases, shortcut: shortcut)
    }

    static let all: [CommandDescriptor] = [
        descriptor(.newSession, "New Session", .session,
                   ["new", "create", "новая сессия", "создать сессию"],
                   .init(key: "n", modifiers: command, display: "⌘N")),
        descriptor(.newSessionInCurrentProject, "New Session in Current Project", .session,
                   ["new here", "same project", "новая сессия в проекте", "создать здесь"]),
        descriptor(.recentSessions, "Recent Sessions", .session,
                   ["recent", "history", "недавние сессии", "история сессий"]),
        descriptor(.filterSessions, "Filter Sessions", .session,
                   ["filter", "search", "фильтр сессий", "поиск сессий"],
                   .init(key: "f", modifiers: command, display: "⌘F")),
        descriptor(.selectPreviousSession, "Select Previous Session", .session,
                   ["previous session", "предыдущая сессия", "перейти назад"],
                   .init(key: "[", modifiers: command, display: "⌘[")),
        descriptor(.selectNextSession, "Select Next Session", .session,
                   ["next session", "следующая сессия", "перейти вперед"],
                   .init(key: "]", modifiers: command, display: "⌘]")),
        descriptor(.selectSession1, "Select Session 1", .session,
                   ["jump session 1", "перейти к сессии 1"],
                   .init(key: "1", modifiers: command, display: "⌘1")),
        descriptor(.selectSession2, "Select Session 2", .session,
                   ["jump session 2", "перейти к сессии 2"],
                   .init(key: "2", modifiers: command, display: "⌘2")),
        descriptor(.selectSession3, "Select Session 3", .session,
                   ["jump session 3", "перейти к сессии 3"],
                   .init(key: "3", modifiers: command, display: "⌘3")),
        descriptor(.selectSession4, "Select Session 4", .session,
                   ["jump session 4", "перейти к сессии 4"],
                   .init(key: "4", modifiers: command, display: "⌘4")),
        descriptor(.selectSession5, "Select Session 5", .session,
                   ["jump session 5", "перейти к сессии 5"],
                   .init(key: "5", modifiers: command, display: "⌘5")),
        descriptor(.selectSession6, "Select Session 6", .session,
                   ["jump session 6", "перейти к сессии 6"],
                   .init(key: "6", modifiers: command, display: "⌘6")),
        descriptor(.selectSession7, "Select Session 7", .session,
                   ["jump session 7", "перейти к сессии 7"],
                   .init(key: "7", modifiers: command, display: "⌘7")),
        descriptor(.selectSession8, "Select Session 8", .session,
                   ["jump session 8", "перейти к сессии 8"],
                   .init(key: "8", modifiers: command, display: "⌘8")),
        descriptor(.selectSession9, "Select Session 9", .session,
                   ["jump session 9", "перейти к сессии 9"],
                   .init(key: "9", modifiers: command, display: "⌘9")),
        descriptor(.killSession, "Kill Session", .session,
                   ["kill", "stop", "terminate", "завершить сессию", "остановить сессию"]),
        descriptor(.renameSession, "Rename Session", .session,
                   ["rename", "переименовать сессию", "название сессии"],
                   .init(key: "r", modifiers: commandShift, display: "⌘⇧R")),
        descriptor(.restartSession, "Restart Session", .session,
                   ["restart", "reload", "перезапустить сессию", "рестарт сессии"]),
        descriptor(.restartAllClaudeSessions, "Restart All Claude Sessions", .session,
                   ["restart all claude", "перезапустить все сессии claude", "рестарт всех claude"]),
        descriptor(.moveSessionUp, "Move Session Up", .session,
                   ["reorder up", "move earlier", "переместить сессию вверх", "поднять сессию"]),
        descriptor(.moveSessionDown, "Move Session Down", .session,
                   ["reorder down", "move later", "переместить сессию вниз", "опустить сессию"]),

        descriptor(.createGitHubIssue, "Create GitHub Issue", .git,
                   ["new issue", "github issue", "создать задачу github", "новый issue"]),
        descriptor(.openIssueList, "Open Issue List", .git,
                   ["issues", "list issues", "список задач", "открыть issues"]),
        descriptor(.promoteWorktree, "Promote Worktree to Root", .git,
                   ["promote", "worktree root", "перенести worktree в корень", "сделать основной веткой"]),
        descriptor(.deleteSessionBranch, "Delete Session Branch", .git,
                   ["delete branch", "remove branch", "удалить ветку сессии", "удалить branch"]),
        descriptor(.cleanupMergedBranches, "Cleanup Merged Branches", .git,
                   ["cleanup branches", "merged", "очистить слитые ветки", "удалить merged ветки"]),
        descriptor(.returnToRepositoryRoot, "Return to Repository Root", .git,
                   ["return root", "leave worktree", "вернуться в корень репозитория", "выйти из worktree"]),

        descriptor(.splitTerminalVertically, "Split Terminal Vertically", .terminal,
                   ["vertical split", "split right", "вертикальный сплит", "разделить терминал вертикально"],
                   .init(key: "d", modifiers: command, display: "⌘D")),
        descriptor(.splitTerminalHorizontally, "Split Terminal Horizontally", .terminal,
                   ["horizontal split", "split below", "горизонтальный сплит", "разделить терминал горизонтально"],
                   .init(key: "d", modifiers: commandShift, display: "⌘⇧D")),
        descriptor(.closeTerminalSplit, "Close Terminal Split", .terminal,
                   ["close split", "remove shell", "закрыть сплит", "убрать разделение терминала"],
                   .init(key: "w", modifiers: command, display: "⌘W")),

        descriptor(.toggleSessionsPanel, "Toggle Sessions Panel", .view,
                   ["show hide sessions", "панель сессий", "показать сессии", "скрыть сессии"]),
        descriptor(.toggleInspector, "Toggle Inspector", .view,
                   ["show hide inspector", "инспектор", "показать инспектор", "скрыть инспектор"]),
        descriptor(.toggleAgentTrace, "Toggle Agent Trace", .view,
                   ["trace panel", "agent log", "трассировка агента", "панель trace"]),
        descriptor(.toggleStatusBar, "Toggle Status Bar", .view,
                   ["footer", "status bar", "строка состояния", "нижняя панель"]),
        descriptor(.toggleTopBar, "Toggle Top Bar", .view,
                   ["header", "top bar", "верхняя панель", "заголовок"]),
        descriptor(.toggleTheme, "Toggle Theme", .view,
                   ["dark light", "color theme", "сменить тему", "темная светлая тема"]),
        descriptor(.cycleUsagePlacement, "Cycle Limits/Clock Position", .view,
                   ["usage position", "clock position", "позиция лимитов", "позиция часов"]),
        descriptor(.showLimitsDetail, "Show Limits Detail", .view,
                   ["usage limits", "claude codex limits", "показать лимиты", "детали лимитов"],
                   .init(key: "l", modifiers: command, display: "⌘L")),
        descriptor(.focusSessionList, "Focus Session List", .view,
                   ["focus sessions", "фокус на сессии", "перейти к списку сессий"],
                   .init(key: "1", modifiers: .control, display: "⌃1")),
        descriptor(.focusAgent, "Focus Agent", .view,
                   ["focus agent terminal", "фокус на агент", "перейти к агенту"],
                   .init(key: "2", modifiers: .control, display: "⌃2")),
        descriptor(.focusIssues, "Focus Issues", .view,
                   ["focus issues", "фокус на задачи", "перейти к issues"],
                   .init(key: "3", modifiers: .control, display: "⌃3")),
        descriptor(.focusTerminalSplit, "Focus Terminal Split", .view,
                   ["focus shell split", "фокус на сплит терминала", "перейти к shell"],
                   .init(key: "4", modifiers: .control, display: "⌃4")),
        descriptor(.focusTrace, "Focus Trace", .view,
                   ["focus agent trace", "фокус на трассировку", "перейти к trace"],
                   .init(key: "5", modifiers: .control, display: "⌃5")),
        descriptor(.showKeyboardHelp, "Show Keyboard Help", .view,
                   ["keys", "shortcuts", "помощь по клавишам", "горячие клавиши"]),

        descriptor(.addProject, "Add Project", .project,
                   ["register project", "добавить проект", "подключить проект"]),
        descriptor(.removeProject, "Remove Project", .project,
                   ["unregister project", "удалить проект", "убрать проект"]),
        descriptor(.renameProject, "Rename Project", .project,
                   ["project name", "переименовать проект", "название проекта"]),

        descriptor(.settings, "Settings…", .app,
                   ["preferences", "configuration", "настройки", "параметры приложения"],
                   .init(key: ",", modifiers: command, display: "⌘,")),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func descriptor(for command: AppCommand) -> CommandDescriptor {
        precondition(byID[command] != nil, "missing command descriptor: \(command)")
        return byID[command]!
    }

    static let sessionSelectionCommands: [AppCommand] = [
        .selectSession1, .selectSession2, .selectSession3,
        .selectSession4, .selectSession5, .selectSession6,
        .selectSession7, .selectSession8, .selectSession9,
    ]

    static let sessionCyclingCommands: [AppCommand] = [
        .selectPreviousSession, .selectNextSession,
    ]
}
