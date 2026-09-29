import Foundation

/// Scene value of a Review window: one window per worktree toplevel;
/// `openWindow` with an equal value raises the existing window.
struct ReviewWindowKey: Codable, Hashable {
    static let sceneID = "review"
    let worktree: String
}

/// Who asked for the window: the default send target, and the project whose
/// sessions may be targets.
struct ReviewLaunch: Equatable {
    let originSession: String
    let projectRoot: String
}
