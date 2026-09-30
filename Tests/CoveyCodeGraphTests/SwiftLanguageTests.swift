import XCTest
@testable import CoveyCodeGraph

final class SwiftLanguageTests: XCTestCase {
    private func declarations(_ text: String) -> [String] {
        (SwiftLanguage().parse(text).syntax as! SwiftSyntax).declarations
    }

    func testTopLevelDeclarationsAfterAttributesAndModifiers() {
        let text = """
        import Foundation
        @MainActor
        public final class PaymentClient {
            func nested() {}
            struct Inner {}
        }
        @available(macOS 14, *) public struct RetryPolicy {}
        enum Mode { case a }
        protocol Payable {}
        actor Ledger {}
        typealias Money = Decimal
        func retry() {}
        extension String { func notTopLevel() {} }
          struct Indented {}
        private func ==(a: Mode, b: Mode) -> Bool { true }
        """
        XCTAssertEqual(declarations(text),
                       ["PaymentClient", "RetryPolicy", "Mode", "Payable", "Ledger", "Money", "retry"])
    }

    func testDeclarationsInCommentsAndStringsDoNotCount() {
        let text = "// class Fake {}\nlet s = \"\"\"\nclass AlsoFake {}\n\"\"\"\nclass Real {}"
        XCTAssertEqual(declarations(text), ["Real"])
    }

    func testOnlyUniqueNamesOfThreeOrMoreCharactersResolve() async throws {
        let fake = FakeProvider(head: [
            "A.swift": "struct Dup {}\nstruct Ok {}\nstruct Unique {}\nextension Other {}",
            "B.swift": "struct Dup {}",
            "C.swift": "let x = Unique()\nlet y = Dup()\nlet z = Ok()\n// Other",
            "D.swift": "struct Other {}",
        ])
        let side = try await makeSide(fake, languages: [SwiftLanguage()])
        let resolver = side.resolver(for: SwiftLanguage())
        let source = try await side.parsed("C.swift")!
        let resolved = try await resolver.resolve(source, from: "C.swift")
        XCTAssertEqual(resolved.compactMap { $0 }, [Resolution(target: "A.swift", names: ["Unique"])])
        XCTAssertEqual(resolved.count, source.referenceLines.count)
        let keywords = try await resolver.keywords(for: "A.swift")
        XCTAssertEqual(keywords, ["Unique"])
        let otherKeywords = try await resolver.keywords(for: "D.swift")
        XCTAssertEqual(otherKeywords, ["Other"])
    }

    /// A side owns its resolvers; if a resolver owned its side back, every
    /// build would leave both sides and all the file text they read in memory.
    func testAResolverDoesNotKeepItsSideOrStoreAlive() async throws {
        weak var weakSide: SideIndex?
        weak var weakStore: SourceStore?
        try await {
            let fake = FakeProvider(head: ["A.swift": "struct Unique {}", "B.swift": "let x = Unique()"])
            let side = try await makeSide(fake, languages: [SwiftLanguage()])
            weakSide = side
            weakStore = side.store
            let resolver = side.resolver(for: SwiftLanguage())
            let source = try await side.parsed("B.swift")!
            let resolved = try await resolver.resolve(source, from: "B.swift")
            XCTAssertEqual(resolved.compactMap { $0 }, [Resolution(target: "A.swift", names: ["Unique"])])
        }()
        XCTAssertNil(weakSide, "the resolver keeps its side alive")
        XCTAssertNil(weakStore, "the resolver keeps the store, and every file text it read, alive")
    }
}
