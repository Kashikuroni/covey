import XCTest
@testable import CoveyCodeGraph

final class SourceStoreTests: XCTestCase {
    func testPathsNormalizeAndStayInsideTheRepository() {
        XCTAssertEqual(Paths.dirname("a/b/c.rs"), "a/b")
        XCTAssertEqual(Paths.dirname("c.rs"), "")
        XCTAssertEqual(Paths.basename("a/b/c.rs"), "c.rs")
        XCTAssertEqual(Paths.join("", "x.ts"), "x.ts")
        XCTAssertEqual(Paths.normalize("web/src", "../lib/./x"), "web/lib/x")
        XCTAssertEqual(Paths.normalize("", "./x"), "x")
        XCTAssertNil(Paths.normalize("web", "../../x"))
        XCTAssertTrue(Paths.contains("", "a/b"))
        XCTAssertTrue(Paths.contains("a", "a/b"))
        XCTAssertFalse(Paths.contains("a", "ab/c"))
    }

    func testBaseReadsOfUnchangedFilesGoToHead() async throws {
        let fake = FakeProvider(common: ["same.swift": "struct Same {}"],
                                base: ["edit.swift": "struct Old {}"], head: ["edit.swift": "struct New {}"])
        let store = makeStore(fake, languages: [SwiftLanguage()], changedBasePaths: ["edit.swift"])
        let same = try await store.text("same.swift", .base)
        let edit = try await store.text("edit.swift", .base)
        XCTAssertEqual(same, "struct Same {}")
        XCTAssertEqual(edit, "struct Old {}")
        XCTAssertEqual(fake.readPaths(.base), ["edit.swift"])
        XCTAssertEqual(fake.readPaths(.head), ["same.swift"])
        _ = try await store.text("same.swift", .head)
        XCTAssertEqual(fake.readPaths(.head), ["same.swift"], "one read per file and side")
    }

    func testOversizedAndBinaryFilesReadAsNil() async throws {
        // "struct Ok {}" is exactly 12 bytes: at the limit is still fine.
        let fake = FakeProvider(head: ["big.swift": String(repeating: "x", count: 13),
                                       "bin.swift": "a\u{0}b", "ok.swift": "struct Ok {}"])
        let store = makeStore(fake, languages: [SwiftLanguage()], limits: GraphLimits(maxFileBytes: 12))
        let big = try await store.text("big.swift", .head)
        let bin = try await store.parsed("bin.swift", .head)
        let ok = try await store.parsed("ok.swift", .head)
        XCTAssertNil(big)
        XCTAssertNil(bin)
        XCTAssertNotNil(ok)
    }

    func testOtherLanguagesParseToNil() async throws {
        let fake = FakeProvider(head: ["README.md": "# hi"])
        let parsed = try await makeStore(fake, languages: [SwiftLanguage()]).parsed("README.md", .head)
        XCTAssertNil(parsed)
    }

    func testParsesAreCachedByPathAndContent() async throws {
        let cache = ParseCache()
        let v1 = FakeProvider(head: ["a.swift": "struct A {}"])
        _ = try await makeStore(v1, languages: [SwiftLanguage()], cache: cache).parsed("a.swift", .head)
        _ = try await makeStore(v1, languages: [SwiftLanguage()], cache: cache).parsed("a.swift", .head)
        XCTAssertEqual(cache.parseCount, 1)
        let v2 = FakeProvider(head: ["a.swift": "struct A2 {}"])
        let store = makeStore(v2, languages: [SwiftLanguage()], cache: cache)
        _ = try await store.parsed("a.swift", .head)
        XCTAssertEqual(cache.parseCount, 2)
        cache.retain(only: store.usedKeys)
        XCTAssertEqual(cache.count, 1)
    }
}
