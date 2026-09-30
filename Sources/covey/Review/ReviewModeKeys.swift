import Foundation

/// One key-down in the main window while Review is shown, reduced to what
/// the decision needs. `ContentView`'s key monitor fills it from the NSEvent.
struct ReviewModeKeyInput: Equatable {
    var key: ReviewKeyEvent
    var isRepeat = false
    /// Physical ⌘W (kVK_ANSI_W with ⌘ alone), whatever the layout.
    var isCommandW = false
    /// The first responder is a single-line field's editor (the path filter).
    var fieldEditorFocused = false
    /// The first responder is any text view (a field or the composer).
    var textInputFocused = false
    /// The ⌘P palette is up.
    var paletteOpen = false
    /// A sheet of the main window is up (Settings, …); its keys reach this
    /// monitor because the window scope includes sheets.
    var sheetOpen = false
    /// A main-window overlay (limits, help) is up.
    var appOverlayOpen = false
    /// Review's send sheet or keys overlay is up.
    var reviewModalOpen = false
}

enum ReviewModeKeyDecision: Equatable {
    /// Hand the event on: text fields, menus, the palette, sheets.
    case pass
    /// Eat the event.
    case swallow
    /// Esc in a single-line field: end editing there and nothing else.
    case endEditing
    /// A main-window overlay owns the keys: run the sessions key path.
    case sessions
    /// `ReviewModel.perform`, except `.closeReview`, which leaves Review.
    case perform(ReviewKeyAction)
}

/// The Review half of the main window's key monitor (formerly the Review
/// window's own monitor), pure so it can be tested.
enum ReviewModeKeys {
    /// Held keys that would flip-flop a toggle. Plan E adds its links key here.
    static let noRepeat: Set<ReviewKeyAction> = [.toggleReviewed, .toggleFullFile, .showKeys]

    static func decide(_ input: ReviewModeKeyInput) -> ReviewModeKeyDecision {
        let blocked = input.paletteOpen || input.sheetOpen
        if input.isCommandW { return blocked ? .swallow : .perform(.closeReview) }
        let context = ReviewKeyContext(textInputFocused: input.textInputFocused,
                                       modalOpen: input.reviewModalOpen)
        if input.key.command {
            // ⌘W typed on another layout is still Review's; every other
            // ⌘-key belongs to the menus.
            guard !blocked, ReviewKeyRouter.route(input.key, context: context) == .closeReview else {
                return .pass
            }
            return .perform(.closeReview)
        }
        if blocked { return .pass }
        if input.appOverlayOpen { return .sessions }
        // Routed, Esc would close the diff or drop a composer draft while the
        // field kept focus.
        if input.key.isEscape, input.fieldEditorFocused { return .endEditing }
        guard let action = ReviewKeyRouter.route(input.key, context: context) else { return .pass }
        if input.isRepeat, noRepeat.contains(action) { return .swallow }
        return .perform(action)
    }
}
