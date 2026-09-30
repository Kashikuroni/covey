import Foundation

/// A file's syntax: what its text says, before any repository knowledge.
/// Cached by content, so it must not depend on the side or other files.
struct ParsedSource: Sendable {
    /// 1-based line of each reference; the language's syntax lists the
    /// references in the same order.
    var referenceLines: [Int]
    /// Every identifier outside comments and strings → its lines.
    var wordLines: [String: [Int]]
    /// The language's own syntax (`SwiftSyntax`, `RustSyntax`, …).
    var syntax: any Sendable
}

/// Where one reference lands on one side.
struct Resolution: Hashable {
    var target: String
    /// Names the reference uses from `target` (the arrow label).
    var names: [String]
    /// Module segments consumed on the way. A head result shallower than the
    /// base one means the module the reference names is gone.
    var depth: Int = 0
}

/// One supported language. Stateless; per-side state lives in its resolver.
protocol SourceLanguage: Sendable {
    /// Stable id: one resolver per language per side.
    var id: String { get }
    func owns(_ path: String) -> Bool
    /// Lexes and parses; pure, so the result can be cached by content.
    func parse(_ text: String) -> ParsedSource
    func makeResolver(_ side: SideIndex) -> any ReferenceResolver
}

/// A language's view of one side of the repository.
protocol ReferenceResolver: AnyObject {
    /// One entry per reference of `source`, in `referenceLines` order: where
    /// it lands on this side, nil when it does not resolve. `path` is where
    /// the text lives (relative imports start there).
    func resolve(_ source: ParsedSource, from path: String) async throws -> [Resolution?]
    /// Words that a file referencing `path` would contain (for `filesMentioning`).
    func keywords(for path: String) async throws -> [String]
}
