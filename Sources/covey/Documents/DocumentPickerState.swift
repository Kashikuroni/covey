import Foundation

struct DocumentPickerState {
    var query = ""
    var markdownOnly = true
    var selection: String?
    func matches(entries: [DocumentEntry], recents: [String]) -> [DocumentEntry] {
        let ranks = Dictionary(recents.enumerated().map { ($0.element,$0.offset) },uniquingKeysWith:min)
        return entries.filter { (!markdownOnly || $0.isMarkdown) && fuzzyMatch(query,$0.path) }
            .sorted {
                let a = ranks[$0.path] ?? Int.max, b = ranks[$1.path] ?? Int.max
                return a == b ? $0.path < $1.path : a < b
            }
    }
    mutating func reconcileSelection(entries: [DocumentEntry], recents: [String]) {
        let results = matches(entries:entries,recents:recents)
        if !results.contains(where: { $0.path == selection }) { selection = results.first?.path }
    }
}
