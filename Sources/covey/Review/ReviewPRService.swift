import Foundation

struct ReviewPR: Equatable, Identifiable {
    let number: Int
    let state: String            // OPEN / CLOSED / MERGED
    let headRefName: String
    let url: String
    let isDraft: Bool
    let title: String

    var id: Int { number }
}

struct PRSnapshot: Equatable {
    let prs: [ReviewPR]
    let error: String?
}

protocol ReviewPRReading: Sendable {
    func load(root: String) async -> PRSnapshot
    func refresh(root: String) async -> PRSnapshot
}

func prListArgs() -> [String] {
    ["gh", "pr", "list", "--state", "all", "--limit", "100",
     "--json", "number,state,headRefName,url,isDraft,title"]
}

func parsePRList(_ data: Data) -> [ReviewPR] {
    struct Wire: Decodable {
        var number: Int
        var state: String
        var headRefName: String
        var url: String
        var isDraft: Bool
        var title: String
    }
    guard let wire = try? JSONDecoder().decode([Wire].self, from: data) else { return [] }
    return wire.map { ReviewPR(number: $0.number, state: $0.state, headRefName: $0.headRefName,
                               url: $0.url, isDraft: $0.isDraft, title: $0.title) }
}

/// The PR to show for a branch: the live one wins, then the newest number.
func livePR(forBranch branch: String, in prs: [ReviewPR]) -> ReviewPR? {
    let rank = { (pr: ReviewPR) -> Int in pr.state == "OPEN" ? 1 : 0 }
    return prs.filter { $0.headRefName == branch }
        .max { lhs, rhs in
            (rank(lhs), lhs.number) < (rank(rhs), rhs.number)
        }
}

/// gh-backed PR list per repository: one call at a time, 5-minute cache.
final class ReviewPRService: ReviewPRReading, @unchecked Sendable {
    static let ghNotFoundMessage =
        "gh CLI not found — install it (brew install gh), then `gh auth login`"

    private let runner: ([String]) async -> GhRun?
    private let ttl: TimeInterval
    private let lock = NSLock()
    private var cache: [String: (fetched: Date, snapshot: PRSnapshot)] = [:]
    private static let queue = DispatchQueue(label: "review.pr.gh")

    init(ttl: TimeInterval = 300,
         runner: (([String]) async -> GhRun?)? = nil) {
        self.ttl = ttl
        self.runner = runner ?? { args in
            await withCheckedContinuation { continuation in
                Self.queue.async {
                    continuation.resume(returning: runGhSync(args: args))
                }
            }
        }
    }

    func load(root: String) async -> PRSnapshot {
        let now = Date()
        let cached: (fetched: Date, snapshot: PRSnapshot)? = lock.withLock { cache[root] }
        if let cached, now.timeIntervalSince(cached.fetched) < ttl { return cached.snapshot }
        return await fetchAndCache(root: root)
    }

    func refresh(root: String) async -> PRSnapshot {
        await fetchAndCache(root: root)
    }

    private func fetchAndCache(root: String) async -> PRSnapshot {
        let snapshot = await Self.fetch(root: root, runner: runner)
        lock.withLock { cache[root] = (Date(), snapshot) }
        return snapshot
    }

    private static func fetch(root: String,
                              runner: ([String]) async -> GhRun?) async -> PRSnapshot {
        guard let run = await runner(prListArgs()) else {
            return PRSnapshot(prs: [], error: ghNotFoundMessage)
        }
        guard run.status == 0 else {
            let message = String(decoding: run.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return PRSnapshot(prs: [], error: message.isEmpty ? "gh pr list failed" : message)
        }
        return PRSnapshot(prs: parsePRList(run.stdout), error: nil)
    }
}

/// Synchronous gh run for the serial queue; same env enrichment as runGh.
func runGhSync(args: [String]) -> GhRun? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    p.environment = ghEnvironment(base: ProcessInfo.processInfo.environment,
                                  home: NSHomeDirectory())
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch { return nil }
    let stdout = out.fileHandleForReading.readDataToEndOfFile()
    let stderr = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return GhRun(status: p.terminationStatus, stdout: stdout, stderr: stderr)
}
