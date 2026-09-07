import SwiftUI

/// A local event monitor is application-wide. Limit workspace shortcuts to
/// its own window so the menu-bar panel keeps native keyboard behavior.
@MainActor
final class WorkspaceWindowScope {
    weak var window: NSWindow?

    func contains(_ candidate: NSWindow?) -> Bool {
        guard let window, let candidate else { return false }
        return candidate === window || candidate.sheetParent === window
    }
}

struct WorkspaceWindowReader: NSViewRepresentable {
    let scope: WorkspaceWindowScope

    func makeNSView(context: Context) -> ScopeView { ScopeView(scope: scope) }
    func updateNSView(_ nsView: ScopeView, context: Context) {}

    final class ScopeView: NSView {
        let scope: WorkspaceWindowScope

        init(scope: WorkspaceWindowScope) {
            self.scope = scope
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scope.window = window
        }
    }
}
