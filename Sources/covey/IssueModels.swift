import Foundation

/// gh's --state filter; `next()` is the `o` key cycle in the list.
enum IssueState: String, CaseIterable, Equatable {
    case open, closed, all
    func next() -> IssueState {
        let all = IssueState.allCases
        let i = all.firstIndex(of: self)!
        return all[(i + 1) % all.count]
    }
}

/// gh issue close --reason values.
enum CloseReason: String, Equatable {
    case completed = "completed"
    case notPlanned = "not planned"
}

/// One GitHub label as `gh` emits it (extra JSON keys are ignored).
struct GhLabel: Decodable, Equatable {
    var name: String
    var color: String
}

/// A PR that will close the issue (gh's closedByPullRequestsReferences).
struct GhPRRef: Decodable, Equatable {
    var number: Int
    var url: String
}

/// One GitHub issue from `gh issue list --json ...`. `author` is flattened
/// to the login; a deleted account decodes as "".
struct GhIssue: Decodable, Equatable {
    var number: Int
    var title: String
    var body: String
    var state: String          // "OPEN" / "CLOSED"
    var author: String
    var labels: [GhLabel]
    var updatedAt: Date
    var url: String
    var linkedPRs: [GhPRRef]

    var isOpen: Bool { state == "OPEN" }
}

extension GhIssue {
    private struct Author: Decodable { var login: String }
    private enum CodingKeys: String, CodingKey {
        case number, title, body, state, author, labels, updatedAt, url
        case linkedPRs = "closedByPullRequestsReferences"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        state = try c.decode(String.self, forKey: .state)
        author = (try? c.decode(Author.self, forKey: .author).login) ?? ""
        labels = try c.decodeIfPresent([GhLabel].self, forKey: .labels) ?? []
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        url = try c.decode(String.self, forKey: .url)
        linkedPRs = (try? c.decodeIfPresent([GhPRRef].self, forKey: .linkedPRs)) ?? []
    }
}

/// Issues from `gh issue list --json` stdout; nil when the JSON is broken.
func parseIssues(_ data: Data) -> [GhIssue]? {
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    return try? dec.decode([GhIssue].self, from: data)
}

/// Labels from `gh label list --json name,color` stdout.
func parseLabels(_ data: Data) -> [GhLabel]? {
    try? JSONDecoder().decode([GhLabel].self, from: data)
}

/// Session name for "session from issue": "#12 title". validateCreate
/// forbids ':' and '.', so both are stripped; whitespace collapses; the
/// result is cut to 60 characters.
func sessionNameForIssue(number: Int, title: String) -> String {
    let cleaned = title
        .replacingOccurrences(of: ":", with: " ")
        .replacingOccurrences(of: ".", with: " ")
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let name = cleaned.isEmpty ? "#\(number)" : "#\(number) \(cleaned)"
    guard name.count > 60 else { return name }
    return String(name.prefix(60)).trimmingCharacters(in: .whitespaces)
}

/// gh flags for a label edit: what to --add-label / --remove-label,
/// sorted for stable args.
func labelDiff(original: [String], edited: [String]) -> (add: [String], remove: [String]) {
    let o = Set(original), e = Set(edited)
    return (add: e.subtracting(o).sorted(), remove: o.subtracting(e).sorted())
}

/// True for covey's session-from-issue naming: "#N" exactly or "#N ..." —
/// "#12" must not match "#123".
func sessionNameMatchesIssue(_ name: String, number: Int) -> Bool {
    let tag = "#\(number)"
    return name == tag || name.hasPrefix("\(tag) ")
}

/// Exactly two rules (spec §2): a /-,-,_-token equals "N", or the name
/// contains "#N" with a token boundary on the right.
func branchMatchesIssue(_ branch: String, number: Int) -> Bool {
    let n = String(number)
    let tokens = branch.split { "/-_".contains($0) }.map(String.init)
    if tokens.contains(n) { return true }
    // "#N" with a token boundary on the right (e.g. "hotfix/#12-scroll").
    // Walk every occurrence: the first may fail the boundary ("#123") while
    // a later one passes.
    let tag = "#\(n)"
    var search = branch[...]
    while let r = search.range(of: tag) {
        let after = r.upperBound
        if after == branch.endIndex || "/-_".contains(branch[after]) { return true }
        search = branch[after...]
    }
    return false
}

/// Compact age for the card: now / Xm / Xh / Xd / Xw.
func relativeAge(from: Date, to: Date) -> String {
    let s = Int(to.timeIntervalSince(from))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86_400 { return "\(s / 3600)h" }
    if s < 7 * 86_400 { return "\(s / 86_400)d" }
    return "\(s / (7 * 86_400))w"
}

/// First non-empty body line for the card's preview row.
func bodyPreview(_ body: String) -> String? {
    body.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty }
}

/// Parses a 6-digit GitHub label hex ("d73a4a" or "#d73a4a") to 0xRRGGBB.
/// nil for empty/wrong-length/non-hex input.
func parseHexColor(_ s: String) -> UInt32? {
    let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
    guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
    return v
}

/// Perceptual (sRGB-weighted) luminance of 0xRRGGBB, 0…1.
func relativeLuminance(_ rgb: UInt32) -> Double {
    let r = Double((rgb >> 16) & 0xFF) / 255
    let g = Double((rgb >> 8) & 0xFF) / 255
    let b = Double(rgb & 0xFF) / 255
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

/// Linear per-channel blend of `rgb` toward `target` by fraction t (0…1).
func blend(_ rgb: UInt32, toward target: UInt32, _ t: Double) -> UInt32 {
    func chan(_ shift: UInt32) -> UInt32 {
        let a = Double((rgb >> shift) & 0xFF)
        let b = Double((target >> shift) & 0xFF)
        return UInt32((a + (b - a) * t).rounded())
    }
    return (chan(16) << 16) | (chan(8) << 8) | chan(0)
}

/// How far a label color is pulled toward the theme foreground: 0 keeps the raw
/// GitHub color, 1 replaces it with the theme text color. Tune here.
let labelThemeBlend = 0.4

/// Colors for a GitHub label chip, pulled toward the theme so raw GitHub hues
/// settle into the ayu palette instead of clashing on the card. Both the dot and
/// the text blend `labelThemeBlend` of the way toward the theme foreground
/// (Tokens.t1 base): the hue survives, the loudness drops into ayu's matte tone,
/// and low-contrast labels (pale on light, near-black on dark) get lifted toward
/// the readable end for free. nil when the hex is empty/invalid so the caller can
/// fall back to a neutral token.
func labelChipColors(hex: String, darkTheme: Bool) -> (dot: UInt32, text: UInt32)? {
    guard let rgb = parseHexColor(hex) else { return nil }
    // Theme foreground — keep in sync with Tokens.dark/.light `t1`.
    let fg: UInt32 = darkTheme ? 0xCCCAC2 : 0x5C6166
    let themed = blend(rgb, toward: fg, labelThemeBlend)
    return (dot: themed, text: themed)
}

/// The card's description block: the whole body, edge-trimmed, or nil when
/// blank. (bodyPreview stays for first-line-only callers.)
func issueDescription(_ body: String) -> String? {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
