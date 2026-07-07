import Foundation

/// Enough to recreate a session after a restart. `resumeCmd` is the Claude Code
/// `--resume <uuid>` command from a clean shutdown; nil for fresh/non-Claude.
public struct PersistedSession: Codable, Equatable {
    public var dir: String
    public var agent: String
    public var resumeCmd: String?
    public init(dir: String, agent: String, resumeCmd: String? = nil) {
        self.dir = dir; self.agent = agent; self.resumeCmd = resumeCmd
    }
}

/// A recently-stopped session, kept so it can be re-launched from the Recent tab.
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

public let maxRecents = 20

/// Move `entry` to the front of `recents`: drop any existing entry with the same
/// name (so a re-stopped session moves up without duplicating), then truncate to
/// `maxRecents`. Port of amux-core `push_recent`.
public func pushRecent(_ recents: inout [RecentSession], _ entry: RecentSession) {
    recents.removeAll { $0.name == entry.name }
    recents.insert(entry, at: 0)
    if recents.count > maxRecents { recents.removeLast(recents.count - maxRecents) }
}

/// Compact age string (port of timeutil.rs humanize_age): 42s, 5m, 3h, 2d.
public func humanizeAge(_ secs: Int64) -> String {
    let s = max(0, secs)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86_400 { return "\(s / 3600)h" }
    return "\(s / 86_400)d"
}

/// The issue composer's per-project draft: survives closing the pane and
/// GUI restarts; cleared after a successful `gh issue create`.
public struct IssueDraft: Codable, Equatable {
    public var title: String
    public var body: String
    public var assignMe: Bool
    public init(title: String = "", body: String = "", assignMe: Bool = false) {
        self.title = title; self.body = body; self.assignMe = assignMe
    }
}

/// Persisted UI state (`~/.covey/state.json`). Owned by the GUI. Optional scalars
/// are omitted from JSON when nil (Swift synthesizes `encodeIfPresent`); empty
/// collections round-trip as `[]`/`{}`.
public struct PersistedState: Codable, Equatable {
    // wired this slice
    public var theme: String?
    public var splitPct: Int?
    public var recents: [RecentSession]
    // schema-only (round-trip, no UI this slice)
    public var order: [String]
    public var projectOrder: [String]
    public var projectNames: [String: String]
    public var projectNotes: [String: String]
    public var notes: [String: String]
    public var drafts: [String: String]
    public var sessions: [String: PersistedSession]
    public var fontScale: Int?
    public var sbWidth: Int?
    public var showSessions: Bool?
    public var showFooter: Bool?
    public var showHeader: Bool?
    public var showInspector: Bool?
    public var vimMode: Bool?
    /// Split axis per parent session name ("v"/"h") for the companion pane.
    public var splitAxes: [String: String]?
    /// Issue composer drafts keyed by project root.
    public var issueDrafts: [String: IssueDraft]?
    /// The inspector's note/issue vertical split mode.
    public var inspectorSplit: Bool?
    /// Registered project roots: projects the sidebar shows even with
    /// zero live sessions (the note -> issue -> session pipeline entry).
    public var projects: [String]?
    public var lastVersion: String?

    public init(
        theme: String? = nil, splitPct: Int? = nil, recents: [RecentSession] = [],
        order: [String] = [], projectOrder: [String] = [],
        projectNames: [String: String] = [:], projectNotes: [String: String] = [:],
        notes: [String: String] = [:], drafts: [String: String] = [:],
        sessions: [String: PersistedSession] = [:],
        fontScale: Int? = nil, sbWidth: Int? = nil,
        showSessions: Bool? = nil, showFooter: Bool? = nil, showHeader: Bool? = nil,
        showInspector: Bool? = nil, vimMode: Bool? = nil,
        splitAxes: [String: String]? = nil,
        issueDrafts: [String: IssueDraft]? = nil,
        inspectorSplit: Bool? = nil,
        projects: [String]? = nil,
        lastVersion: String? = nil
    ) {
        self.theme = theme; self.splitPct = splitPct; self.recents = recents
        self.order = order; self.projectOrder = projectOrder
        self.projectNames = projectNames; self.projectNotes = projectNotes
        self.notes = notes; self.drafts = drafts; self.sessions = sessions
        self.fontScale = fontScale; self.sbWidth = sbWidth
        self.showSessions = showSessions; self.showFooter = showFooter
        self.showHeader = showHeader
        self.showInspector = showInspector; self.vimMode = vimMode
        self.splitAxes = splitAxes
        self.issueDrafts = issueDrafts
        self.inspectorSplit = inspectorSplit
        self.projects = projects
        self.lastVersion = lastVersion
    }
}
