import Foundation
import CoreGraphics
import CoveyCodeGraph

/// One arrow's cubic Bézier, from the file that uses to the file it uses
/// (Review spec part 3, «Стрелки»), in world coordinates.
struct EdgeRoute: Equatable {
    var start: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    var end: CGPoint

    /// The least a curve bends away from its end points.
    static let minBend: CGFloat = 36

    /// Target below: bottom edge → top edge. Same line: side → facing side,
    /// arched a little so it clears the cards between. Target above: out of
    /// the side facing it and around into the target's same side.
    static func between(_ from: CGRect, _ to: CGRect) -> EdgeRoute {
        if to.minY >= from.maxY {
            let start = CGPoint(x: from.midX, y: from.maxY)
            let end = CGPoint(x: to.midX, y: to.minY)
            let bend = max(minBend, (end.y - start.y) / 2)
            return EdgeRoute(start: start, control1: CGPoint(x: start.x, y: start.y + bend),
                             control2: CGPoint(x: end.x, y: end.y - bend), end: end)
        }
        let right = to.midX >= from.midX
        if to.maxY <= from.minY {
            let start = CGPoint(x: right ? from.maxX : from.minX, y: from.midY)
            let end = CGPoint(x: right ? to.maxX : to.minX, y: to.midY)
            let bulge = max(minBend, (start.y - end.y) / 4)
            let out = right ? max(start.x, end.x) + bulge : min(start.x, end.x) - bulge
            return EdgeRoute(start: start, control1: CGPoint(x: out, y: start.y),
                             control2: CGPoint(x: out, y: end.y), end: end)
        }
        let start = CGPoint(x: right ? from.maxX : from.minX, y: from.midY)
        let end = CGPoint(x: right ? to.minX : to.maxX, y: to.midY)
        let reach = abs(end.x - start.x)
        let bend = max(minBend, reach / 2) * (right ? 1 : -1)
        let lift = min(80, reach / 5)
        return EdgeRoute(start: start, control1: CGPoint(x: start.x + bend, y: start.y - lift),
                         control2: CGPoint(x: end.x - bend, y: end.y - lift), end: end)
    }

    func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * start.x + b * control1.x + c * control2.x + d * end.x,
                       y: a * start.y + b * control1.y + c * control2.y + d * end.y)
    }

    /// Where the ⚠ of a broken link and a focused link's names sit.
    var midpoint: CGPoint { point(at: 0.5) }

    /// The arrowhead: tip at `end`, pointing along the curve's last tangent.
    func arrowHead(length: CGFloat = 9, width: CGFloat = 7) -> [CGPoint] {
        var dx = end.x - control2.x
        var dy = end.y - control2.y
        if dx == 0 && dy == 0 {
            dx = end.x - start.x
            dy = end.y - start.y
        }
        let norm = max((dx * dx + dy * dy).squareRoot(), 0.0001)
        let ux = dx / norm, uy = dy / norm
        let base = CGPoint(x: end.x - ux * length, y: end.y - uy * length)
        let half = width / 2
        return [end,
                CGPoint(x: base.x - uy * half, y: base.y + ux * half),
                CGPoint(x: base.x + uy * half, y: base.y - ux * half)]
    }
}

/// How a link is drawn: `kept` muted solid, `added` accent solid, `removed`
/// red dashed, `broken` red bold with ⚠, a link to a neighbour dotted muted.
/// Broken and removed win over the neighbour style: they are the news.
enum EdgeStroke: Equatable, CaseIterable {
    case kept, added, removed, broken, neighbour

    static func of(_ link: Link, changed: Set<String>) -> EdgeStroke {
        switch link.state {
        case .broken: return .broken
        case .removed: return .removed
        case .kept, .added:
            guard changed.contains(link.from), changed.contains(link.to) else { return .neighbour }
            return link.state == .added ? .added : .kept
        }
    }

    var dash: [CGFloat] {
        switch self {
        case .removed: return [6, 4]
        case .neighbour: return [1.5, 4]
        case .kept, .added, .broken: return []
        }
    }

    var width: CGFloat { self == .broken ? 2.4 : 1.3 }

    /// The legend's words.
    var label: String {
        switch self {
        case .kept: return "kept"
        case .added: return "added"
        case .removed: return "removed"
        case .broken: return "broken"
        case .neighbour: return "unchanged file"
        }
    }
}

/// The names on a focused link: two, then "+N"; all of them in the tooltip.
enum EdgeLabel {
    static func text(_ names: [String]) -> String {
        let shown = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? "\(shown) +\(names.count - 2)" : shown
    }

    static func tooltip(_ names: [String]) -> String { names.joined(separator: ", ") }
}
