import Foundation
import CoreGraphics
import CoveyCodeGraph

/// One card on the canvas: a changed file, or an unchanged neighbour of the
/// selected file. Nodes are files only — a folder is a caption, never a card.
struct GraphCard: Equatable {
    enum Kind: Equatable {
        case changed
        /// Unchanged; uses the selected file (left half of the neighbour row).
        case user
        /// Unchanged; used by the selected file (right half).
        case used
    }

    let path: String
    let kind: Kind
    let rect: CGRect
}

/// Small muted text on the canvas: a folder path, "No links", "used by", "uses".
struct GraphCaption: Equatable {
    let text: String
    let origin: CGPoint
}

struct GraphLayoutInput: Equatable {
    /// Changed files.
    var files: [String]
    /// Every link, visible or not; nil while links are not computed or are
    /// unavailable.
    var links: [Link]?
    var selected: String?
    /// Unchanged files that use the selected file / that it uses; empty
    /// while its neighbour row is not shown.
    var users: [String] = []
    var used: [String] = []
    /// "+N more" was pressed on the selected card.
    var expanded = false
}

/// The graph's positions (Review spec part 3, «Раскладка»), top to bottom,
/// in world coordinates. Pure and deterministic: the same input gives the
/// same frames.
struct GraphLayout: Equatable {
    var cards: [GraphCard] = []
    var captions: [GraphCaption] = []
    /// Neighbours left out of the row until "+N more" is pressed.
    var hiddenNeighbours = 0

    static let cardSize = CGSize(width: 260, height: 104)
    static let neighbourSize = CGSize(width: 260, height: 184)
    static let columnGap: CGFloat = 48
    static let lineGap: CGFloat = 56
    static let groupGap: CGFloat = 40
    static let captionHeight: CGFloat = 24
    static let perLine = 4
    static let neighbourLimit = 8
    static let rootCaption = "./"
    static let noLinksCaption = "No links"
    static let usersCaption = "used by"
    static let usedCaption = "uses"

    /// Left edge of the neighbour row's right half ("uses").
    static let usedX = column(perLine) + columnGap

    static func column(_ index: Int) -> CGFloat {
        CGFloat(index) * (cardSize.width + columnGap)
    }

    var bounds: CGRect? {
        cards.map(\.rect).reduce(nil) { acc, rect in acc?.union(rect) ?? rect }
    }

    /// Card frames by path, for edges and centering.
    var rects: [String: CGRect] {
        Dictionary(cards.map { ($0.path, $0.rect) }, uniquingKeysWith: { first, _ in first })
    }

    /// 1. Changed files grouped by parent folder (a caption, not a node).
    /// 2. Groups top to bottom by folder dependencies: a folder whose files
    ///    use another's stands above it.
    /// 3. Inside a group, left to right by the same rule; 4 per line.
    /// 4. Files with no link at all: a "No links" block at the bottom.
    /// 5. The selected file's neighbour row right under its line.
    /// 6. Without links: folders in path order, no bottom block.
    /// Built from every link whatever is visible, so showing or hiding
    /// links never moves a card.
    static func make(_ input: GraphLayoutInput) -> GraphLayout {
        let files = Set(input.files).sorted()
        let changed = Set(files)
        var placed = files
        var bottom: [String] = []
        var folderEdges: [(String, String)] = []
        var innerEdges: [String: [(String, String)]] = [:]
        if let links = input.links {
            var linked = Set<String>()
            for link in links {
                let fromChanged = changed.contains(link.from)
                let toChanged = changed.contains(link.to)
                if fromChanged { linked.insert(link.from) }
                if toChanged { linked.insert(link.to) }
                guard fromChanged, toChanged, link.from != link.to else { continue }
                let fromFolder = folder(link.from)
                let toFolder = folder(link.to)
                if fromFolder == toFolder {
                    innerEdges[fromFolder, default: []].append((link.from, link.to))
                } else {
                    folderEdges.append((fromFolder, toFolder))
                }
            }
            placed = files.filter(linked.contains)
            bottom = files.filter { !linked.contains($0) }
        }
        let groups = Dictionary(grouping: placed, by: folder)
        var layout = GraphLayout()
        var y: CGFloat = 0
        for dir in order(Array(groups.keys), edges: folderEdges) {
            let members = order(groups[dir] ?? [], edges: innerEdges[dir] ?? [])
            layout.place(members, caption: dir.isEmpty ? rootCaption : dir, y: &y, input: input)
            y += groupGap
        }
        if !bottom.isEmpty {
            layout.place(bottom, caption: noLinksCaption, y: &y, input: input)
        }
        return layout
    }

    /// `nodes` in dependency order: `(from, to)` means from uses to, so from
    /// comes first. With no node free of incoming edges (a cycle) the one
    /// with the fewest wins; ties go to the smaller path.
    static func order(_ nodes: [String], edges: [(String, String)]) -> [String] {
        let nodes = Set(nodes).sorted()
        var index: [String: Int] = [:]
        for (i, node) in nodes.enumerated() { index[node] = i }
        var targets = Array(repeating: Set<Int>(), count: nodes.count)
        var incoming = Array(repeating: 0, count: nodes.count)
        for (from, to) in edges {
            guard let a = index[from], let b = index[to], a != b, targets[a].insert(b).inserted else { continue }
            incoming[b] += 1
        }
        var done = Array(repeating: false, count: nodes.count)
        var result: [String] = []
        result.reserveCapacity(nodes.count)
        for _ in nodes.indices {
            var pick = -1
            for i in nodes.indices where !done[i] {
                if pick < 0 || incoming[i] < incoming[pick] { pick = i }
                if incoming[pick] == 0 { break }
            }
            done[pick] = true
            result.append(nodes[pick])
            for target in targets[pick] where !done[target] { incoming[target] -= 1 }
        }
        return result
    }

    private static func folder(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// A caption, then `paths` in lines of `perLine`; the neighbour row
    /// follows the selected file's line.
    private mutating func place(_ paths: [String], caption: String, y: inout CGFloat,
                                input: GraphLayoutInput) {
        captions.append(GraphCaption(text: caption, origin: CGPoint(x: 0, y: y)))
        y += Self.captionHeight
        for start in stride(from: 0, to: paths.count, by: Self.perLine) {
            let line = paths[start..<min(start + Self.perLine, paths.count)]
            for (column, path) in line.enumerated() {
                cards.append(GraphCard(path: path, kind: .changed,
                                       rect: CGRect(origin: CGPoint(x: Self.column(column), y: y),
                                                    size: Self.cardSize)))
            }
            y += Self.cardSize.height + Self.lineGap
            if let selected = input.selected, line.contains(selected) {
                placeNeighbours(input, y: &y)
            }
        }
    }

    /// Users on the left, used files on the right, each by path, at most
    /// `neighbourLimit` a side until expanded, wrapping every `perLine`. A
    /// file on both sides is placed once, as a user.
    private mutating func placeNeighbours(_ input: GraphLayoutInput, y: inout CGFloat) {
        let users = Set(input.users).sorted()
        let used = Set(input.used).subtracting(users).sorted()
        guard !users.isEmpty || !used.isEmpty else { return }
        let shownUsers = input.expanded ? users : Array(users.prefix(Self.neighbourLimit))
        let shownUsed = input.expanded ? used : Array(used.prefix(Self.neighbourLimit))
        hiddenNeighbours = users.count - shownUsers.count + used.count - shownUsed.count
        if !shownUsers.isEmpty {
            captions.append(GraphCaption(text: Self.usersCaption, origin: CGPoint(x: 0, y: y)))
        }
        if !shownUsed.isEmpty {
            captions.append(GraphCaption(text: Self.usedCaption, origin: CGPoint(x: Self.usedX, y: y)))
        }
        y += Self.captionHeight
        let left = Self.grid(shownUsers, kind: .user, x: 0, y: y)
        let right = Self.grid(shownUsed, kind: .used, x: Self.usedX, y: y)
        cards += left.cards + right.cards
        y += max(left.height, right.height) + Self.lineGap
    }

    private static func grid(_ paths: [String], kind: GraphCard.Kind, x: CGFloat,
                             y: CGFloat) -> (cards: [GraphCard], height: CGFloat) {
        let cards = paths.enumerated().map { i, path in
            GraphCard(path: path, kind: kind, rect: CGRect(
                origin: CGPoint(x: x + column(i % perLine),
                                y: y + CGFloat(i / perLine) * (neighbourSize.height + lineGap)),
                size: neighbourSize))
        }
        let lines = (paths.count + perLine - 1) / perLine
        let height = lines == 0 ? 0 : CGFloat(lines) * neighbourSize.height + CGFloat(lines - 1) * lineGap
        return (cards, height)
    }
}
