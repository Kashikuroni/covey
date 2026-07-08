import Foundation

/// Single tuning point for the issue UI type scale (spec: +2pt toward the
/// agent pane's text; adjust here, not per-view).
enum IssueFont {
    static let title: CGFloat = 15
    static let body: CGFloat = 13
    static let meta: CGFloat = 12
    static let mono: CGFloat = 15
    static let monoSmall: CGFloat = 12
}
