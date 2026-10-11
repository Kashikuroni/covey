import XCTest
@testable import covey

final class DocumentPickerStateTests: XCTestCase {
    func testFilterQueryAndRecentOrdering() {
        let entries = [DocumentEntry(path:"b.md",isMarkdown:true,byteCount:1), DocumentEntry(path:"a.MARKDOWN",isMarkdown:true,byteCount:1), DocumentEntry(path:"src/main.swift",isMarkdown:false,byteCount:1)]
        var picker = DocumentPickerState()
        XCTAssertEqual(picker.matches(entries:entries,recents:["deleted","b.md"]).map(\.path),["b.md","a.MARKDOWN"])
        picker.markdownOnly = false
        picker.query = "smw"
        XCTAssertEqual(picker.matches(entries:entries,recents:[]).map(\.path),["src/main.swift"])
        picker.query = "missing"
        picker.selection = "b.md"
        picker.reconcileSelection(entries:entries,recents:[])
        XCTAssertNil(picker.selection)
    }
}
