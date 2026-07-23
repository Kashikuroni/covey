import Foundation

/// A CLI-agnostic normalized entry in a session's agent trace. Produced by the
/// daemon's per-CLI adapters, persisted by `TraceStore`, streamed over IPC.
public struct TraceEvent: Codable, Equatable {
    public var seq: Int              // monotonic per session; the sinceSeq cursor
    public var agent: AgentRef       // main agent or a nested subagent
    public var cli: CLIKind
    public var cliVersion: String?
    public var model: String?
    public var effort: String?
    public var timestamp: Date
    public var kind: Kind
    public var raw: String           // the source JSON for this item (full-JSON expand)

    public init(seq: Int, agent: AgentRef, cli: CLIKind, cliVersion: String? = nil,
                model: String? = nil, effort: String? = nil, timestamp: Date,
                kind: Kind, raw: String) {
        self.seq = seq; self.agent = agent; self.cli = cli
        self.cliVersion = cliVersion; self.model = model; self.effort = effort
        self.timestamp = timestamp; self.kind = kind; self.raw = raw
    }

    public enum CLIKind: String, Codable, Equatable { case claudeCode, codex }

    /// Main agent (`id == nil`) or a nested subagent keyed by an opaque id
    /// (Claude sidechain-chain root uuid / Codex sub-agent id).
    public struct AgentRef: Codable, Equatable, Hashable {
        public var id: String?
        public var label: String?
        public static let main = AgentRef(id: nil, label: nil)
        public init(id: String?, label: String? = nil) { self.id = id; self.label = label }
    }

    public struct TokenUsage: Codable, Equatable {
        public var input, output, cacheRead, cacheCreate, reasoning, total: Int
        public var contextWindow: Int?
        public init(input: Int, output: Int, cacheRead: Int, cacheCreate: Int,
                    reasoning: Int, total: Int, contextWindow: Int? = nil) {
            self.input = input; self.output = output; self.cacheRead = cacheRead
            self.cacheCreate = cacheCreate; self.reasoning = reasoning
            self.total = total; self.contextWindow = contextWindow
        }
    }

    public enum Kind: Codable, Equatable {
        case turnStarted
        case turnCompleted(durationMs: Int?)
        case assistantText(preview: String)
        case thinking(preview: String)
        case toolCall(id: String, name: String)
        case toolResult(callId: String, isError: Bool, preview: String)
        case fileEdit(path: String, added: Int, removed: Int, diff: String?)
        case tokenUsage(TokenUsage)
        case rateLimit(usedPercent: Double, resetsAt: Date?, plan: String?)
        case webSearch(query: String?)
        case other(label: String)
    }
}
