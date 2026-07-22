import CoveyKit

/// Case-insensitive subsequence match: the characters of `pattern` appear in
/// `text` in order (not necessarily contiguously). Empty pattern -> true.
func fuzzyMatch(_ pattern: String, _ text: String) -> Bool {
    if pattern.isEmpty { return true }
    var it = text.lowercased().makeIterator()
    for want in pattern.lowercased() {
        var found = false
        while let c = it.next() {
            if c == want { found = true; break }
        }
        if !found { return false }
    }
    return true
}

/// Compatibility for the current RecentSheet. The rebuilt sheet uses
/// `recentResults` and removes this wrapper in the same change.
func filterRecents(_ recents: [RecentSession], filter: String) -> [RecentSession] {
    guard !filter.isEmpty else { return recents }
    return recents.filter { fuzzyMatch(filter, $0.name) || fuzzyMatch(filter, $0.dir) }
}
