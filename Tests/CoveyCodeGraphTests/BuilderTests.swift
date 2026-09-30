import XCTest
@testable import CoveyCodeGraph

/// Link states, merging, usages and failures — on Swift fixtures, the
/// simplest language to write.
final class BuilderTests: XCTestCase {
    func testModifiedFileLinksAreKeptAddedOrRemoved() async {
        let fake = FakeProvider(
            common: ["Pay.swift": "struct PayClient {}", "Retry.swift": "struct RetryPolicy {}",
                     "Log.swift": "struct Logger {}"],
            base: ["Checkout.swift": "let c = PayClient()\nlet l = Logger()"],
            head: ["Checkout.swift": "let c = PayClient()\nlet r = RetryPolicy()"])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), [
            "Checkout.swift → Log.swift removed [Logger]",
            "Checkout.swift → Pay.swift kept [PayClient]",
            "Checkout.swift → Retry.swift added [RetryPolicy]",
        ])
        XCTAssertTrue(graph.complete)
        XCTAssertNil(graph.note)
    }

    func testAddedFileLinksAreAddedAndDeletedFileLinksRemoved() async {
        let fake = FakeProvider(common: ["Core.swift": "struct CoreKit {}"],
                                base: ["Old.swift": "let c = CoreKit()"],
                                head: ["New.swift": "let c = CoreKit()"])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), [
            "New.swift → Core.swift added [CoreKit]",
            "Old.swift → Core.swift removed [CoreKit]",
        ])
    }

    func testIncomingLinksFromUnchangedFilesAreKept() async {
        let fake = FakeProvider(common: ["Uses.swift": "let a = Money(v: 1)", "Other.swift": "let b = 1"],
                                base: ["Money.swift": "struct Money { var v: Int }"],
                                head: ["Money.swift": "struct Money { var v: Int; var c = 0 }"])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), ["Uses.swift → Money.swift kept [Money]"])
    }

    func testDeletedDeclarationLeavesBrokenLinksButARenameCarriesItsNames() async {
        let fake = FakeProvider(
            common: ["Report.swift": "let l = Ledger()\nlet s = Stamp()"],
            base: ["Ledger.swift": "actor Ledger {}", "Stamp.swift": "struct Stamp {}"],
            head: ["Books.swift": "actor Ledger {}"])
        let graph = await buildGraph(fake, renames: ["Ledger.swift": "Books.swift"])
        XCTAssertEqual(describe(graph), [
            "Report.swift → Books.swift kept [Ledger]",
            "Report.swift → Stamp.swift broken [Stamp]",
        ])
    }

    func testChangedFileStillUsingADeletedNameIsBrokenNotRemoved() async {
        let fake = FakeProvider(base: ["Gone.swift": "struct Vanished {}", "Main.swift": "let v = Vanished()"],
                                head: ["Main.swift": "let v = Vanished()\nlet w = 2"])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), ["Main.swift → Gone.swift broken [Vanished]"])
    }

    func testParallelReferencesMergeAndSelfLinksAreDropped() async {
        let fake = FakeProvider(head: [
            "A.swift": "struct Beta {}\nstruct Alpha {}",
            "B.swift": "let y = Beta()\nlet x = Alpha()\nstruct Bravo {}\nlet z = Bravo()",
        ])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), ["B.swift → A.swift added [Alpha, Beta]"])
    }

    func testUsagesAreTheLinesOfFromWhereTheNamesOccur() async {
        let long = "let wide = PayClient() // " + String(repeating: "x", count: 300)
        let fake = FakeProvider(head: [
            "Pay.swift": "struct PayClient {}\nfunc charge() {}",
            "Cart.swift": "import Foundation\r\n\r\n    let client = PayClient()\r\n// PayClient in a comment\r\nfunc total() { charge() }\r\n\(long)\r\n",
        ])
        let graph = await buildGraph(fake)
        let sites = graph.usages[LinkKey(from: "Cart.swift", to: "Pay.swift")] ?? []
        XCTAssertEqual(sites.map(\.line), [3, 5, 6])
        XCTAssertEqual(sites.first, UsageSite(path: "Cart.swift", line: 3, text: "let client = PayClient()"))
        XCTAssertEqual(sites[1].text, "func total() { charge() }")
        XCTAssertEqual(sites[2].text.count, UsageSite.maxTextLength)
    }

    func testRemovedLinkUsagesComeFromTheBaseText() async {
        let fake = FakeProvider(common: ["Log.swift": "struct Logger {}"],
                                base: ["Main.swift": "let a = 1\nlet l = Logger()"],
                                head: ["Main.swift": "let a = 2"])
        let graph = await buildGraph(fake)
        XCTAssertEqual(graph.usages[LinkKey(from: "Main.swift", to: "Log.swift")],
                       [UsageSite(path: "Main.swift", line: 2, text: "let l = Logger()")])
    }

    func testBinaryOversizedAndOtherLanguageFilesAreNodesWithoutLinks() async {
        let fake = FakeProvider(
            common: ["Core.swift": "struct CoreKit {}"],
            head: ["Blob.swift": "let c = CoreKit()\u{0}", "notes.md": "CoreKit",
                   "Big.swift": "let c = CoreKit()" + String(repeating: " ", count: 64)])
        let graph = await buildGraph(fake, limits: GraphLimits(maxFileBytes: 64))
        XCTAssertEqual(graph, LinkGraph(links: [], usages: [:], complete: true, note: nil))
    }

    func testProviderFailureMakesTheGraphUnavailable() async {
        let fake = FakeProvider(head: ["A.swift": "struct Alpha {}"])
        fake.failure = FakeError(description: "git exited 128")
        let graph = await buildGraph(fake)
        XCTAssertEqual(graph, .unavailable("git exited 128"))
    }

    func testRebuildReusesParsesAndDropsStaleVersions() async {
        let builder = LinkGraphBuilder()
        let v1 = FakeProvider(common: ["Pay.swift": "struct PayClient {}"],
                              base: ["Cart.swift": "let a = 1"], head: ["Cart.swift": "let c = PayClient()"])
        _ = await builder.build(changes: v1.changes(), provider: v1)
        let first = builder.cache.parseCount
        _ = await builder.build(changes: v1.changes(), provider: v1)
        XCTAssertEqual(builder.cache.parseCount, first, "nothing changed, nothing re-parsed")
        let v2 = FakeProvider(common: ["Pay.swift": "struct PayClient {}"],
                              base: ["Cart.swift": "let a = 1"], head: ["Cart.swift": "let c = PayClient(); _ = 2"])
        let graph = await builder.build(changes: v2.changes(), provider: v2)
        XCTAssertEqual(builder.cache.parseCount, first + 1, "only the edited file")
        XCTAssertEqual(builder.cache.count, 3, "Pay, Cart at base, Cart at head — the old Cart is gone")
        XCTAssertEqual(describe(graph), ["Cart.swift → Pay.swift added [PayClient]"])
    }
}
