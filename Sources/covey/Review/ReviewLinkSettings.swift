import Foundation
import Observation

/// «Показать связи» and «Связи при фокусе» (Review spec, part 3). One
/// instance lives on `AppModel`, which persists it, and is handed to the live
/// review, so the canvas button, the `L` key and Settings change the same
/// values.
@Observable @MainActor
final class ReviewLinkSettings {
    /// Every link between changed files is drawn.
    var showLinks: Bool
    /// A hovered or selected file shows its links.
    var linksOnFocus: Bool
    /// Persists the values after a toggle (`AppModel` sets it).
    @ObservationIgnored var changed: (() -> Void)?

    init(showLinks: Bool = false, linksOnFocus: Bool = true) {
        self.showLinks = showLinks
        self.linksOnFocus = linksOnFocus
    }

    /// The canvas button and the `L` key.
    func toggleShowLinks() {
        showLinks.toggle()
        changed?()
    }
}
