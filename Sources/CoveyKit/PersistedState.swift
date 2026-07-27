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
    public var branch: String?
    public init(name: String, dir: String, agent: String,
                resumeCmd: String? = nil, stoppedAt: Int64? = nil,
                branch: String? = nil) {
        self.name = name; self.dir = dir; self.agent = agent
        self.resumeCmd = resumeCmd; self.stoppedAt = stoppedAt
        self.branch = branch
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
    public var labels: [String]
    public init(title: String = "", body: String = "", assignMe: Bool = false,
                labels: [String] = []) {
        self.title = title; self.body = body; self.assignMe = assignMe; self.labels = labels
    }
    // Custom decode so drafts persisted before `labels` existed still load
    // (synthesized Decodable ignores property defaults for missing keys).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        assignMe = try c.decodeIfPresent(Bool.self, forKey: .assignMe) ?? false
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
    }
}

/// A single usage window's percentage + reset time — the persistence mirror
/// of both Claude's fixed windows and Codex's labeled primary/secondary
/// windows. The live types (`Usage`, `CodexRateLimitsSnapshot`) live in the
/// `covey` target, which depends on `CoveyKit` (not the reverse), so they
/// can't be referenced here directly — `covey`'s `UsagePersistence.swift`
/// converts between the two.
public struct PersistedUsageWindow: Codable, Equatable {
    public var utilization: Double
    public var resetUnix: Int64?
    public init(utilization: Double, resetUnix: Int64? = nil) {
        self.utilization = utilization; self.resetUnix = resetUnix
    }
}

/// Persistence mirror of Claude's `Usage`.
public struct PersistedUsage: Codable, Equatable {
    public var fiveHour: PersistedUsageWindow?
    public var sevenDay: PersistedUsageWindow?
    public var sevenDaySonnet: PersistedUsageWindow?
    public init(fiveHour: PersistedUsageWindow? = nil, sevenDay: PersistedUsageWindow? = nil,
                sevenDaySonnet: PersistedUsageWindow? = nil) {
        self.fiveHour = fiveHour; self.sevenDay = sevenDay; self.sevenDaySonnet = sevenDaySonnet
    }
}

/// Persistence mirror of Codex's `CodexRateLimitsSnapshot`. The label is
/// stored alongside each window because Codex windows carry a label
/// ("5h"/"7d"/"primary"/"secondary") that isn't fixed like Claude's.
public struct PersistedCodexUsage: Codable, Equatable {
    public var primaryLabel: String?
    public var primary: PersistedUsageWindow?
    public var secondaryLabel: String?
    public var secondary: PersistedUsageWindow?
    public init(primaryLabel: String? = nil, primary: PersistedUsageWindow? = nil,
                secondaryLabel: String? = nil, secondary: PersistedUsageWindow? = nil) {
        self.primaryLabel = primaryLabel; self.primary = primary
        self.secondaryLabel = secondaryLabel; self.secondary = secondary
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
    /// Which drawer the inspector shows: "notes" (Note/Issue) or "trace".
    public var inspectorMode: String?
    /// Registered project roots: projects the sidebar shows even with
    /// zero live sessions (the note -> issue -> session pipeline entry).
    public var projects: [String]?
    /// Usage-limit alert markers: window key ("5h"/"7d") -> resetUnix of the
    /// window cycle already alerted (0 when resets_at was absent).
    public var usageNotified: [String: Int64]?
    /// Top-bar placement for the usage chip and fullscreen clock:
    /// "left", "center", or "right". Unknown values are resolved by the GUI.
    public var usagePlacement: String?
    /// Issue number bound to a session, keyed by session name. Migrated on
    /// rename so the binding survives (the name is the session's durable
    /// identity — it is preserved across relaunch, only rename changes it).
    public var issueBySession: [String: Int]?
    public var lastVersion: String?
    /// Per-provider limits display/polling toggle (nil = enabled) and the
    /// last successfully fetched snapshot, so a disabled provider — or a
    /// cold start before the first poll lands — still has something to show.
    public var claudeUsageEnabled: Bool?
    public var codexUsageEnabled: Bool?
    public var claudeUsage: PersistedUsage?
    public var claudePlan: String?
    public var codexUsage: PersistedCodexUsage?
    public var codexPlan: String?

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
        inspectorMode: String? = nil,
        projects: [String]? = nil,
        usageNotified: [String: Int64]? = nil,
        usagePlacement: String? = nil,
        issueBySession: [String: Int]? = nil,
        lastVersion: String? = nil,
        claudeUsageEnabled: Bool? = nil,
        codexUsageEnabled: Bool? = nil,
        claudeUsage: PersistedUsage? = nil,
        claudePlan: String? = nil,
        codexUsage: PersistedCodexUsage? = nil,
        codexPlan: String? = nil
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
        self.inspectorMode = inspectorMode
        self.projects = projects
        self.usageNotified = usageNotified
        self.usagePlacement = usagePlacement
        self.issueBySession = issueBySession
        self.lastVersion = lastVersion
        self.claudeUsageEnabled = claudeUsageEnabled
        self.codexUsageEnabled = codexUsageEnabled
        self.claudeUsage = claudeUsage
        self.claudePlan = claudePlan
        self.codexUsage = codexUsage
        self.codexPlan = codexPlan
    }
}
