import XCTest
import CoveyKit
@testable import covey

private actor ControlledDocumentLoader: DocumentFileLoading {
    var requests: [(String, CheckedContinuation<DocumentFileSnapshot, Error>)] = []
    func load(path: String, context: DocumentContext) async throws -> DocumentFileSnapshot {
        try await withCheckedThrowingContinuation { requests.append((path,$0)) }
    }
    var count: Int { requests.count }
    func finish(_ index: Int, text: String = "text") {
        let (path, continuation) = requests[index]
        continuation.resume(returning:.text(path:path,text:text,isMarkdown:true,byteCount:text.utf8.count))
    }
    func fail(_ index: Int) { requests[index].1.resume(throwing:DocumentAccessError.unavailable) }
}
private struct NoDocumentWatch: DocumentWatching {
    func watch(path: String, context: DocumentContext, onChange: @escaping @Sendable () -> Void) -> DocumentWatchToken { .init(cancel:{}) }
}
@MainActor final class DocumentReaderModelTests: XCTestCase {
    private func wait(_ count: Int, _ loader: ControlledDocumentLoader) async {
        for _ in 0..<1000 { if await loader.count >= count { return }; await Task.yield() }
        XCTFail("Load did not start")
    }
    func testNewerNavigationAndRefreshWin() async {
        let loader = ControlledDocumentLoader()
        let reader = DocumentReaderModel(context:.init(sourceSession:"s",root:"/tmp",projectKey:"/tmp"),loader:loader,watcher:NoDocumentWatch())
        let a = Task { await reader.open(.init(path:"a.md")) }
        await wait(1,loader)
        let b = Task { await reader.open(.init(path:"b.md")) }
        await wait(2,loader)
        await loader.finish(1,text:"B")
        await b.value
        await loader.finish(0,text:"A")
        await a.value
        XCTAssertEqual(reader.current?.path,"b.md")
        XCTAssertEqual(reader.snapshot,.text(path:"b.md",text:"B",isMarkdown:true,byteCount:1))
        let old = Task { await reader.refresh() }
        await wait(3,loader)
        let new = Task { await reader.refresh() }
        await wait(4,loader)
        await loader.finish(3,text:"new")
        await new.value
        await loader.finish(2,text:"old")
        await old.value
        XCTAssertEqual(reader.snapshot,.text(path:"b.md",text:"new",isMarkdown:true,byteCount:3))
        reader.stop()
    }
    func testFailureRetainsTextAndHistoryRestoresPosition() async {
        let loader = ControlledDocumentLoader()
        let reader = DocumentReaderModel(context:.init(sourceSession:"s",root:"/tmp",projectKey:"/tmp"),loader:loader,watcher:NoDocumentWatch())
        let a = Task { await reader.open(.init(path:"a.md")) }
        await wait(1,loader); await loader.finish(0); await a.value
        let position = DocumentPosition(anchorID:"section",offset:12,progress:0.4)
        reader.recordPosition(position)
        let refresh = Task { await reader.refresh() }
        await wait(2,loader); await loader.fail(1); await refresh.value
        XCTAssertNotNil(reader.error)
        XCTAssertNotNil(reader.snapshot)
        XCTAssertFalse(reader.canGoBack)
        let b = Task { await reader.open(.init(path:"b.md")) }
        await wait(3,loader); await loader.finish(2); await b.value
        XCTAssertNil(reader.error)
        let back = Task { await reader.goBack() }
        await wait(4,loader); await loader.finish(3); await back.value
        XCTAssertEqual(reader.current?.position,position)
        XCTAssertTrue(reader.canGoForward)
        let c = Task { await reader.open(.init(path:"c.md")) }
        await wait(5,loader); await loader.finish(4); await c.value
        XCTAssertFalse(reader.canGoForward)
        reader.stop()
    }
}
