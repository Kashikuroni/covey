import Foundation

/// Human-readable name for a Claude model id: "claude-fable-5" -> "Fable 5",
/// "claude-haiku-4-5-20251001" -> "Haiku 4.5". One generic rule instead of a
/// lookup table so unknown future ids degrade to the same shape.
func modelDisplayName(_ id: String) -> String {
    var parts = id.split(separator: "-").map(String.init)
    if parts.first == "claude" { parts.removeFirst() }
    if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
        parts.removeLast()                       // date suffix (20251001)
    }
    guard let family = parts.first, !family.isEmpty else { return id }
    let version = parts.dropFirst().joined(separator: ".")
    let name = family.prefix(1).uppercased() + family.dropFirst()
    return version.isEmpty ? name : "\(name) \(version)"
}
