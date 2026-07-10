import Foundation

/// Single tuning point for the issue UI type scale (spec: +2pt toward the
/// agent pane's text; adjust here, not per-view).
enum IssueFont {
    static let title: CGFloat = 15
    static let body: CGFloat = 13
    static let meta: CGFloat = 12
    static let mono: CGFloat = 15
    static let monoSmall: CGFloat = 12
    // card (variant 3a) scale — matches the handoff macro
    static let cardTitle: CGFloat = 14.5
    static let cardDesc: CGFloat = 12.5
    static let cardMeta: CGFloat = 11.5
    static let cardNum: CGFloat = 13
    static let cardTime: CGFloat = 10.5
    static let cardSession: CGFloat = 12
}
