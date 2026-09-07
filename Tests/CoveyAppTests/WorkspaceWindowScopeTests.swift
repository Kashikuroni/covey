import AppKit
import XCTest
@testable import covey

@MainActor
final class WorkspaceWindowScopeTests: XCTestCase {
    func testWorkspaceKeysDoNotReachMenuBarWindow() {
        _ = NSApplication.shared
        let main = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let menu = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel], backing: .buffered, defer: true)
        let scope = WorkspaceWindowScope()
        scope.window = main
        XCTAssertTrue(scope.contains(main))
        XCTAssertFalse(scope.contains(menu))
        XCTAssertFalse(scope.contains(nil))
        scope.window = nil
        XCTAssertFalse(scope.contains(main))
    }
}
