import Foundation

/// Metadata needed to surface (and later relaunch) a session that a dead
/// daemon lost: everything but the live process.
public struct SessionMeta: Codable, Equatable {
    public var name: String
    public var dir: String
    public var agent: String
    public var argv: [String]
    public var created: Int64
    public var worktreeRepo: String?
    public var resumeCmd: String?

    public init(name: String, dir: String, agent: String, argv: [String], created: Int64,
                worktreeRepo: String? = nil, resumeCmd: String? = nil) {
        self.name = name; self.dir = dir; self.agent = agent
        self.argv = argv; self.created = created
        self.worktreeRepo = worktreeRepo; self.resumeCmd = resumeCmd
    }
}

/// Persists the daemon's session registry (live + unclaimed lost metas) as
/// JSON. Daemon-owned (`~/.covey/registry.json`) — the GUI's `state.json`
/// stays the user-facing record (HANDOFF §8 ownership split).
public final class RegistryStore {
    private let path: String

    public init(path: String) {
        self.path = path
    }

    public func load() -> [SessionMeta] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder().decode([SessionMeta].self, from: data)) ?? []
    }

    public func save(_ metas: [SessionMeta]) {
        guard let data = try? JSONEncoder().encode(metas) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
