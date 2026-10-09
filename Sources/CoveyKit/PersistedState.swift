import Foundation

/// Enough to recreate a session after a restart. `resumeCmd` is the Claude Code
/// `--resume <uuid>` command from a clean shutdown; nil for fresh/non-Claude.
public struct PersistedSession: Codable, Equatable {
    public var dir: String
    public var agent: String
    public var resumeCmd: String?
    /// Covey provider this session was created under; nil = anthropic/legacy.
    public var providerId: String?
    public init(dir: String, agent: String, resumeCmd: String? = nil,
                providerId: String? = nil) {
        self.dir = dir; self.agent = agent; self.resumeCmd = resumeCmd
        self.providerId = providerId
    }
    // Custom decode so payloads persisted before `providerId` existed keep
    // decoding (synthesized Decodable ignores property defaults for missing keys).
    enum CodingKeys: String, CodingKey { case dir, agent, resumeCmd, providerId }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dir = try c.decode(String.self, forKey: .dir)
        agent = try c.decode(String.self, forKey: .agent)
        resumeCmd = try c.decodeIfPresent(String.self, forKey: .resumeCmd)
        providerId = try c.decodeIfPresent(String.self, forKey: .providerId)
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
    /// Covey provider this session was created under; nil = anthropic/legacy.
    public var providerId: String?
    public init(name: String, dir: String, agent: String,
                resumeCmd: String? = nil, stoppedAt: Int64? = nil,
                branch: String? = nil, providerId: String? = nil) {
        self.name = name; self.dir = dir; self.agent = agent
        self.resumeCmd = resumeCmd; self.stoppedAt = stoppedAt
        self.branch = branch; self.providerId = providerId
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

/// Persistence mirror of one Codex rate-limit bucket.
public struct PersistedCodexRateLimitBucket: Codable, Equatable {
    public var name: String?
    public var primaryLabel: String?
    public var primaryDurationMinutes: Int?
    public var primary: PersistedUsageWindow?
    public var secondaryLabel: String?
    public var secondaryDurationMinutes: Int?
    public var secondary: PersistedUsageWindow?
    public init(name: String? = nil,
                primaryLabel: String? = nil, primaryDurationMinutes: Int? = nil,
                primary: PersistedUsageWindow? = nil,
                secondaryLabel: String? = nil, secondaryDurationMinutes: Int? = nil,
                secondary: PersistedUsageWindow? = nil) {
        self.name = name
        self.primaryLabel = primaryLabel
        self.primaryDurationMinutes = primaryDurationMinutes
        self.primary = primary
        self.secondaryLabel = secondaryLabel
        self.secondaryDurationMinutes = secondaryDurationMinutes
        self.secondary = secondary
    }
}

/// Persistence mirror of Codex's `CodexRateLimitsSnapshot`. Legacy window
/// fields stay readable while `buckets` preserves the current multi-limit API.
public struct PersistedCodexUsage: Codable, Equatable {
    public var primaryLabel: String?
    public var primaryDurationMinutes: Int?
    public var primary: PersistedUsageWindow?
    public var secondaryLabel: String?
    public var secondaryDurationMinutes: Int?
    public var secondary: PersistedUsageWindow?
    public var buckets: [String: PersistedCodexRateLimitBucket]?
    public init(primaryLabel: String? = nil, primaryDurationMinutes: Int? = nil,
                primary: PersistedUsageWindow? = nil,
                secondaryLabel: String? = nil, secondaryDurationMinutes: Int? = nil,
                secondary: PersistedUsageWindow? = nil,
                buckets: [String: PersistedCodexRateLimitBucket]? = nil) {
        self.primaryLabel = primaryLabel
        self.primaryDurationMinutes = primaryDurationMinutes
        self.primary = primary
        self.secondaryLabel = secondaryLabel
        self.secondaryDurationMinutes = secondaryDurationMinutes
        self.secondary = secondary
        self.buckets = buckets
    }
}

/// Persistence mirror of the GUI's pane tree (`covey` target owns the live
/// `PaneNode`; this target cannot depend on it — same split as
/// `PersistedUsage`). `axis` — "vertical" | "horizontal".
public indirect enum PersistedPaneNode: Codable, Equatable {
    case agent(session: String)
    case split(axis: String, ratio: Double,
               first: PersistedPaneNode, second: PersistedPaneNode)

    // Явный Codable с дискриминатором "type", чтобы формат JSON был
    // самоописанным и стабильным между версиями.
    private enum CodingKeys: String, CodingKey {
        case type, session, axis, ratio, first, second
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "agent":
            self = .agent(session: try c.decode(String.self, forKey: .session))
        case "split":
            self = .split(axis: try c.decode(String.self, forKey: .axis),
                          ratio: try c.decode(Double.self, forKey: .ratio),
                          first: try c.decode(PersistedPaneNode.self, forKey: .first),
                          second: try c.decode(PersistedPaneNode.self, forKey: .second))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                debugDescription: "unknown PaneNode type: \(other)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .agent(let session):
            try c.encode("agent", forKey: .type)
            try c.encode(session, forKey: .session)
        case .split(let axis, let ratio, let first, let second):
            try c.encode("split", forKey: .type)
            try c.encode(axis, forKey: .axis)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(first, forKey: .first)
            try c.encode(second, forKey: .second)
        }
    }
}

/// Which legacy split pair survives migration to the pane tree and which
/// companion shells close (spec: один шелл на проект; первая пара по порядку
/// сайдбара; остальные шеллы закрываются однократно). nil — живых пар нет.
public func splitMigrationChoice(
    parentCompanions: [(parent: String, companion: String)],
    orderedParentNames: [String]
) -> (keep: (parent: String, companion: String), close: [String])? {
    guard !parentCompanions.isEmpty else { return nil }
    let ranked = parentCompanions.sorted { a, b in
        let ia = orderedParentNames.firstIndex(of: a.parent) ?? Int.max
        let ib = orderedParentNames.firstIndex(of: b.parent) ?? Int.max
        if ia != ib { return ia < ib }
        return a.parent < b.parent
    }
    return (keep: ranked[0], close: ranked.dropFirst().map(\.companion))
}

/// One persisted workspace view (Workspace Views). `id`/`agentTree` are always
/// present; every other field is optional so older / partial payloads decode.
public struct PersistedWorkspaceView: Codable, Equatable {
    public var id: String
    public var agentTree: PersistedPaneNode
    /// Hidden shell session name; nil when the zone is closed or its shell is
    /// unlinked (see `terminalOpen`).
    public var terminalShell: String?
    /// true when the terminal zone is open even though `terminalShell` is nil —
    /// keeps the column after a daemon restart dropped the shell, pending relink.
    public var terminalOpen: Bool?
    /// "vertical" (right column) | "horizontal" (bottom band); nil = vertical —
    /// payloads saved before ⌘⇧T existed.
    public var terminalAxis: String?
    /// "issues" | "trace"; nil = inspector hidden.
    public var inspector: String?
    public var agentAreaRatio: Double?

    public init(id: String, agentTree: PersistedPaneNode, terminalShell: String? = nil,
                terminalOpen: Bool? = nil, terminalAxis: String? = nil,
                inspector: String? = nil, agentAreaRatio: Double? = nil) {
        self.id = id
        self.agentTree = agentTree
        self.terminalShell = terminalShell
        self.terminalOpen = terminalOpen
        self.terminalAxis = terminalAxis
        self.inspector = inspector
        self.agentAreaRatio = agentAreaRatio
    }
}

/// Persisted UI state (`~/.covey/state.json`). Owned by the GUI. Optional scalars
/// are omitted from JSON when nil (Swift synthesizes `encodeIfPresent`); empty
/// collections round-trip as `[]`/`{}`.
public struct PersistedState: Codable, Equatable {
    // wired this slice
    public var theme: String?
    /// Active Claude Code provider id ("anthropic" | …); nil = anthropic.
    public var provider: String?
    public var splitPct: Int?
    public var recents: [RecentSession]
    // schema-only (round-trip, no UI this slice)
    public var order: [String]
    public var projectOrder: [String]
    public var projectNames: [String: String]
    public var drafts: [String: String]
    public var sessions: [String: PersistedSession]
    public var fontScale: Int?
    public var sbWidth: Int?
    /// Agent-pane tree of the window (Split Session); nil = single pane.
    /// Legacy: read once by the Workspace Views migration, then nulled.
    public var splitTree: PersistedPaneNode?
    /// Project companion shell pane name; nil = no shell column. Legacy: see
    /// `splitTree`.
    public var companionShell: String?
    /// Agent-area : shell-column width share (0.15...0.85). Legacy: see `splitTree`.
    public var companionRatio: Double?
    /// Workspace Views: every view keyed by id; nil until first migration.
    public var workspaceViews: [PersistedWorkspaceView]?
    /// Workspace Views: session name → owning view id.
    public var viewOfSession: [String: String]?
    public var showSessions: Bool?
    public var showFooter: Bool?
    public var showHeader: Bool?
    public var showInspector: Bool?
    public var vimMode: Bool?
    /// Split axis per parent session name ("v"/"h") for the companion pane.
    /// Legacy, read-only: читается однократной миграцией в `splitTree`, затем
    /// стирается в nil; осмысленно больше не пишется.
    public var splitAxes: [String: String]?
    /// Issue composer drafts keyed by project root.
    public var issueDrafts: [String: IssueDraft]?
    /// Which drawer the inspector shows: "issues" or "trace".
    public var inspectorMode: String?
    /// Registered project roots shown in the sidebar even with zero live sessions.
    public var projects: [String]?
    /// Usage-limit alert markers: window key ("5h"/"7d") -> resetUnix of the
    /// window cycle already alerted (0 when resets_at was absent).
    public var usageNotified: [String: Int64]?
    /// Top-bar placement for the usage chip and fullscreen clock:
    /// "left", "center", or "right". Unknown values are resolved by the GUI.
    public var usagePlacement: String?
    /// Optional for compatibility with older state files; nil means hidden.
    public var menuBarLimitsEnabled: Bool?
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
    /// Review graph: every link between changed files is drawn (the canvas
    /// button and `L`); nil = off.
    public var showLinks: Bool?
    /// Review graph: a hovered or selected file shows its links (Settings →
    /// Review); nil = on.
    public var linksOnFocus: Bool?
    /// Which source drives the Forecast window's top windows block:
    /// "claudeCode" (GLM) or "codex" (GPT); nil = claudeCode.
    public var forecastSource: String?

    public init(
        theme: String? = nil, provider: String? = nil, splitPct: Int? = nil,
        recents: [RecentSession] = [],
        order: [String] = [], projectOrder: [String] = [],
        projectNames: [String: String] = [:], drafts: [String: String] = [:],
        sessions: [String: PersistedSession] = [:],
        fontScale: Int? = nil, sbWidth: Int? = nil,
        splitTree: PersistedPaneNode? = nil,
        companionShell: String? = nil, companionRatio: Double? = nil,
        showSessions: Bool? = nil, showFooter: Bool? = nil, showHeader: Bool? = nil,
        showInspector: Bool? = nil, vimMode: Bool? = nil,
        splitAxes: [String: String]? = nil,
        issueDrafts: [String: IssueDraft]? = nil,
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
        codexPlan: String? = nil,
        workspaceViews: [PersistedWorkspaceView]? = nil,
        viewOfSession: [String: String]? = nil,
        forecastSource: String? = nil
    ) {
        self.theme = theme; self.provider = provider
        self.splitPct = splitPct; self.recents = recents
        self.order = order; self.projectOrder = projectOrder
        self.projectNames = projectNames
        self.drafts = drafts; self.sessions = sessions
        self.fontScale = fontScale; self.sbWidth = sbWidth
        self.splitTree = splitTree
        self.companionShell = companionShell
        self.companionRatio = companionRatio
        self.showSessions = showSessions; self.showFooter = showFooter
        self.showHeader = showHeader
        self.showInspector = showInspector; self.vimMode = vimMode
        self.splitAxes = splitAxes
        self.issueDrafts = issueDrafts
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
        self.workspaceViews = workspaceViews
        self.viewOfSession = viewOfSession
        self.forecastSource = forecastSource
    }
}
