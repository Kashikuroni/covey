import XCTest
@testable import covey

final class LinkURLTests: XCTestCase {
    func testWebSchemesPass() {
        XCTAssertEqual(linkURL(from: "https://example.com/a?b=1")?.absoluteString,
                       "https://example.com/a?b=1")
        XCTAssertNotNil(linkURL(from: "http://localhost:8080"))
        XCTAssertNotNil(linkURL(from: "HTTPS://EXAMPLE.COM"))   // scheme is case-insensitive
    }

    func testNonWebSchemesAndGarbageRejected() {
        XCTAssertNil(linkURL(from: "file:///etc/passwd"))
        XCTAssertNil(linkURL(from: "javascript:alert(1)"))
        XCTAssertNil(linkURL(from: "ssh://host"))
        XCTAssertNil(linkURL(from: "not a url"))
        XCTAssertNil(linkURL(from: ""))
    }
}
