import Foundation
import CoveyCodeGraph

/// What the canvas shows of the links (Review spec part 3, «Видимость
/// связей»): the table of «Показать связи» × «Связи при фокусе», pure.
struct LinkVisibility: Equatable {
    /// Links to draw, in graph order. One whose end has no card on the
    /// canvas (a neighbour past the row's limit) is skipped by the canvas.
    var links: [Link]
    /// The file whose links are in focus: the hovered one, else the selected.
    var focus: String?
    /// The selected file's neighbour row is laid out.
    var showsNeighbours: Bool
    /// Cards at full strength while the focus has visible links; everything
    /// else dims to 40%. nil — nothing dims.
    var lit: Set<String>?

    static let none = LinkVisibility(links: [], focus: nil, showsNeighbours: false, lit: nil)

    /// - `showLinks` on: every link between changed files; a selection adds
    ///   its neighbour row and the links to it.
    /// - off, `linksOnFocus` on: hovering a file shows its links with changed
    ///   files; selecting one shows all its links and its neighbour row.
    /// - both off: cards only.
    /// Hovering never adds the neighbour row, so the layout holds still
    /// under the pointer.
    static func resolve(showLinks: Bool, linksOnFocus: Bool, hovered: String?, selected: String?,
                        changed: Set<String>, links: [Link]) -> LinkVisibility {
        guard showLinks || linksOnFocus else { return .none }
        let touches = { (path: String, link: Link) in link.from == path || link.to == path }
        let visible: [Link]
        let focus: String?
        if showLinks {
            visible = links.filter { link in
                (changed.contains(link.from) && changed.contains(link.to))
                    || selected.map { touches($0, link) } == true
            }
            focus = hovered ?? selected
        } else if let hovered {
            visible = links.filter { link in
                touches(hovered, link) && changed.contains(link.from == hovered ? link.to : link.from)
            }
            focus = hovered
        } else if let selected {
            visible = links.filter { touches(selected, $0) }
            focus = selected
        } else {
            visible = []
            focus = nil
        }
        var lit: Set<String>?
        if let focus {
            let focused = visible.filter { touches(focus, $0) }
            if !focused.isEmpty {
                lit = Set(focused.flatMap { [$0.from, $0.to] })
            }
        }
        return LinkVisibility(links: visible, focus: focus, showsNeighbours: selected != nil, lit: lit)
    }

    /// A link of the focused file: drawn at full strength, with its names.
    func isFocused(_ link: Link) -> Bool {
        guard let focus else { return false }
        return link.from == focus || link.to == focus
    }

    /// The card or link sits outside the focus and fades to 40%.
    func dims(_ path: String) -> Bool { lit.map { !$0.contains(path) } ?? false }

    func dims(_ link: Link) -> Bool { lit != nil && !isFocused(link) }
}
