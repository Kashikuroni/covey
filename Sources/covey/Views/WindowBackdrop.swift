import AppKit
import SwiftUI

/// The window's backdrop: a blur of whatever sits *behind* the window, so the
/// panel cards read as floating on glass.
///
/// `.glassEffect` is the wrong tool here — it blurs content inside the app and
/// is meant for floating elements over it (the help overlay, the limits card,
/// which-key and the toast all use it). A window background needs
/// `behindWindow` blending, which only `NSVisualEffectView` provides.
struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        // Keep the blur when the window is inactive: a terminal is read while
        // another app has focus all the time, and the dimmed state re-tints the
        // whole workspace.
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
