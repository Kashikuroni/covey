import XCTest
import CoveyKit
@testable import covey

@MainActor final class DocumentFileWatcherTests: XCTestCase {
    private func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for:.milliseconds(20))
        }
        return condition()
    }
    func testEditsAtomicReplacementDeletionAndParentRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let parent = root.appendingPathComponent("docs")
        let file = parent.appendingPathComponent("plan.md")
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        func write(_ text: String, atomic: Bool = false) throws { try Data(text.utf8).write(to:file,options:atomic ? .atomic : []) }
        let reader = DocumentReaderModel(context:.init(sourceSession:"s",root:root.path,projectKey:root.path))
        defer { reader.stop() }
        func has(_ text: String) -> Bool {
            guard case .text(_,let actual,_,_) = reader.snapshot else { return false }
            return actual == text && reader.error == nil
        }
        try write("first")
        await reader.open(.init(path:"docs/plan.md"))
        try write("edited")
        let edited = await waitFor { has("edited") }; XCTAssertTrue(edited)
        try write("replaced",atomic:true)
        let replaced = await waitFor { has("replaced") }; XCTAssertTrue(replaced)
        try write("after replacement")
        let again = await waitFor { has("after replacement") }; XCTAssertTrue(again)
        try FileManager.default.removeItem(at:file)
        let missing = await waitFor { reader.error != nil }; XCTAssertTrue(missing)
        XCTAssertNotNil(reader.snapshot)
        try write("recreated")
        let recreated = await waitFor { has("recreated") }; XCTAssertTrue(recreated)
        try FileManager.default.removeItem(at:parent)
        let parentMissing = await waitFor { reader.error != nil }; XCTAssertTrue(parentMissing)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        try write("parent restored")
        let restored = await waitFor { has("parent restored") }; XCTAssertTrue(restored)
        reader.stop()
        try write("after stop")
        try await Task.sleep(for:.milliseconds(600))
        XCTAssertTrue(has("parent restored"))
    }
}
