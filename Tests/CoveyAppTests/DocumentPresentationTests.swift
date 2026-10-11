import XCTest
import CoveyKit
@testable import covey

@MainActor final class DocumentPresentationTests: XCTestCase {
    let context = DocumentContext(sourceSession:"s",root:"/tmp",projectKey:"/tmp")
    func testParserHeadingIdentityAndRenderedSearch() {
        let source = "# Этап *один*\r\n\r\n## Повтор\r\n## Повтор\r\n```md\r\n# Not a heading\r\n```\r\n\r\n[План][ref]\r\n\r\n[ref]: next.md#этап\r\n"
        let document = DocumentPresentation(text:source,path:"spec.md",context:context,sourceMode:false)
        XCTAssertEqual(document.headings.map(\.text),["Этап один","Повтор","Повтор"])
        XCTAssertEqual(document.headings.map(\.id),["этап-один","повтор","повтор-1"])
        XCTAssertTrue(document.html.contains("next.md#"))
        XCTAssertEqual(document.matches("Этап один").count,1)
        XCTAssertEqual(document.matches("*один*").count,0)
        XCTAssertEqual(document.source,source)
    }
    func testSafeRichMarkdownAndPlainSource() {
        let source = "# Title\n\n<script>alert(1)</script>\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n- [x] Done\n- [ ] Todo\n\n![local](image.png)\n\n```unknown\n<safe>\n```"
        let document = DocumentPresentation(text:source,path:"spec.md",context:context,sourceMode:false)
        XCTAssertFalse(document.html.contains("<script>"))
        XCTAssertTrue(document.html.contains("<table>"))
        XCTAssertTrue(document.html.contains("type=\"checkbox\" disabled"))
        XCTAssertTrue(document.html.contains("covey-document://image/"))
        XCTAssertTrue(document.html.contains("&lt;safe&gt;"))
        let plain = DocumentPresentation(text:source,path:"source.txt",context:context,sourceMode:true)
        XCTAssertTrue(plain.headings.isEmpty)
        XCTAssertEqual(plain.matches("[x]").count,1)
    }
}
