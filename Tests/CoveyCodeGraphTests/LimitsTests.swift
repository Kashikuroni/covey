import XCTest
@testable import CoveyCodeGraph

final class LimitsTests: XCTestCase {
    func testCandidatesOverTheCapAreDroppedAndTheGraphIsIncomplete() async {
        var common: [String: String] = [:]
        for i in 0..<5 { common["U\(i).swift"] = "let x = HubThing()" }
        let fake = FakeProvider(common: common, base: ["Hub.swift": "struct HubThing {}"],
                                head: ["Hub.swift": "struct HubThing { var v = 1 }"])
        let graph = await buildGraph(fake, limits: GraphLimits(maxCandidates: 3))
        XCTAssertEqual(describe(graph), [
            "U0.swift → Hub.swift kept [HubThing]",
            "U1.swift → Hub.swift kept [HubThing]",
            "U2.swift → Hub.swift kept [HubThing]",
        ])
        XCTAssertFalse(graph.complete)
        XCTAssertEqual(graph.note, "links incomplete")
    }

    /// The cap applies to the merged list: broad scoped hits (`a0`…`a3`, which
    /// sort first) never crowd out the precise plain ones (`z0`, `z1`).
    func testPlainCandidatesOutrankScopedOnesUnderTheCap() async throws {
        var common = ["z0.stub": "plainword", "z1.stub": "plainword"]
        for i in 0..<4 { common["a\(i).stub"] = "broadword" }
        let fake = FakeProvider(common: common, base: ["core.stub": "one"], head: ["core.stub": "two"])
        let session = BuildSession(changes: fake.changes(), provider: fake, limits: GraphLimits(maxCandidates: 3),
                                   cache: ParseCache(), languages: [CappedStubLanguage()])
        let graph = try await session.run()
        XCTAssertEqual(describe(graph), [
            "a0.stub → core.stub kept",
            "z0.stub → core.stub kept",
            "z1.stub → core.stub kept",
        ])
        XCTAssertFalse(graph.complete)
        XCTAssertEqual(graph.note, LinkGraph.incompleteNote)
    }

    func testSpentBudgetReturnsWhatItHasAsIncomplete() async {
        var head: [String: String] = [:]
        for i in 0..<20 { head["f\(i).ts"] = "import { a } from './f0'\n" }
        let fake = FakeProvider(head: head)
        fake.readDelay = .milliseconds(30)
        let started = ContinuousClock.now
        let graph = await buildGraph(fake, limits: GraphLimits(budget: .milliseconds(100)))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        XCTAssertFalse(graph.complete)
        XCTAssertEqual(graph.note, LinkGraph.incompleteNote)
        XCTAssertLessThan(graph.links.count, 19, "stopped before every file was read")
    }

    func testCancelledBuildStopsEarly() async {
        let fake = FakeProvider(head: ["a.ts": "import './b'\n", "b.ts": ""])
        let task = Task { () -> LinkGraph in
            withUnsafeCurrentTask { $0?.cancel() }
            return await LinkGraphBuilder().build(changes: fake.changes(), provider: fake)
        }
        let graph = await task.value
        XCTAssertFalse(graph.complete)
        XCTAssertTrue(graph.links.isEmpty)
    }

    /// A provider that reports cancellation mid-build is a stopped build, not
    /// an unavailable one: the links found before it are kept.
    func testCancellationThrownByTheProviderEndsAsIncompleteWithWhatWasFound() async {
        let fake = FakeProvider(head: ["a.ts": "import './b'\n", "b.ts": "", "c.ts": "import './b'\n"])
        let provider = FailingProvider(fake, at: "c.ts", error: CancellationError())
        let graph = await LinkGraphBuilder().build(changes: fake.changes(), provider: provider)
        XCTAssertEqual(describe(graph), ["a.ts → b.ts added"])
        XCTAssertFalse(graph.complete)
        XCTAssertEqual(graph.note, LinkGraph.incompleteNote)
    }

    /// Whatever the provider throws once the task is cancelled (git killed by
    /// the cancellation, say) is the cancellation, not a failure.
    func testAnyErrorThrownWhileCancelledEndsAsIncomplete() async {
        let fake = FakeProvider(head: ["a.ts": "import './b'\n", "b.ts": "", "c.ts": "import './b'\n"])
        let provider = FailingProvider(fake, at: "c.ts", error: FakeError(description: "git exited 143"),
                                       cancelling: true)
        let task = Task { await LinkGraphBuilder().build(changes: fake.changes(), provider: provider) }
        let graph = await task.value
        XCTAssertEqual(describe(graph), ["a.ts → b.ts added"])
        XCTAssertFalse(graph.complete)
        XCTAssertEqual(graph.note, LinkGraph.incompleteNote)
    }

    /// `a.ts` imports `./b` on both sides (a kept link). Cancelled while its
    /// base text is read, the head pair alone would read as `added`: a
    /// half-collected change is dropped instead.
    func testCancellationBetweenAChangesHeadAndBaseNeverShowsAWrongState() async {
        let fake = FakeProvider(common: ["b.ts": ""],
                                base: ["a.ts": "import './b'\n"], head: ["a.ts": "import './b'\n// edited\n"])
        let provider = FailingProvider(fake, at: "a.ts", side: .base, error: CancellationError())
        let graph = await LinkGraphBuilder().build(changes: fake.changes(), provider: provider)
        XCTAssertEqual(describe(graph), [])
        XCTAssertFalse(graph.complete)
        XCTAssertEqual(graph.note, LinkGraph.incompleteNote)
    }

    /// `a.ts` is collected whole; `c.ts` is cancelled half-way (any error
    /// counts once the task is cancelled): only `c.ts`'s pairs are dropped.
    func testAnyErrorBetweenAChangesHeadAndBaseWhileCancelledDropsOnlyThatChange() async {
        let fake = FakeProvider(common: ["b.ts": ""],
                                base: ["a.ts": "import './b'\n", "c.ts": "import './b'\n"],
                                head: ["a.ts": "import './b'\n// edited\n", "c.ts": "import './b'\n// edited\n"])
        let provider = FailingProvider(fake, at: "c.ts", side: .base, error: FakeError(description: "killed"),
                                       cancelling: true)
        let task = Task { await LinkGraphBuilder().build(changes: fake.changes(), provider: provider) }
        let graph = await task.value
        XCTAssertEqual(describe(graph), ["a.ts → b.ts kept"])
        XCTAssertFalse(graph.complete)
        XCTAssertEqual(graph.note, LinkGraph.incompleteNote)
    }

    /// Nothing is asked of the provider once the build is out of time.
    func testCancelledBuildDoesNotAskTheProviderForAnything() async throws {
        let spy = SpyProvider(FakeProvider(common: ["z.stub": "plainword"], base: ["core.stub": "one"],
                                           head: ["core.stub": "two"]))
        let session = BuildSession(changes: spy.fake.changes(), provider: spy, limits: .standard,
                                   cache: ParseCache(), languages: [CappedStubLanguage()])
        let task = Task { () -> LinkGraph in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.run()
        }
        let graph = try await task.value
        XCTAssertEqual(spy.calls, [])
        XCTAssertFalse(graph.complete)
        XCTAssertEqual(graph.note, LinkGraph.incompleteNote)
    }

    /// A build that runs out of time during the keyword search skips the
    /// remaining lookups (here the scoped word's).
    func testOutOfTimeDuringTheKeywordSearchSkipsTheRemainingLookups() async throws {
        let spy = SpyProvider(FakeProvider(common: ["z.stub": "plainword", "a.stub": "broadword"],
                                           base: ["core.stub": "one"], head: ["core.stub": "two"]))
        spy.cancelOnMentioning = true
        let session = BuildSession(changes: spy.fake.changes(), provider: spy, limits: .standard,
                                   cache: ParseCache(), languages: [CappedStubLanguage()])
        let task = Task { try await session.run() }
        let graph = try await task.value
        XCTAssertEqual(spy.calls.filter { $0.hasPrefix("filesMentioning") }, ["filesMentioning plainword"])
        XCTAssertEqual(describe(graph), [])
        XCTAssertFalse(graph.complete)
        XCTAssertEqual(graph.note, LinkGraph.incompleteNote)
    }

    /// A crate root used by hundreds of files: every link comes back (the
    /// UI caps what it shows), within the standard budget.
    func testHubFileWithHundredsOfIncomingLinksStaysWithinBudget() async {
        var common: [String: String] = [
            "hub/Cargo.toml": "[package]\nname = \"hub\"\n",
            "app/Cargo.toml": "[package]\nname = \"app\"\n",
            "app/src/lib.rs": (0..<300).map { "mod m\($0);" }.joined(separator: "\n"),
        ]
        for i in 0..<300 { common["app/src/m\(i).rs"] = "use hub::Thing;\npub fn f() { hub::helper(); }\n" }
        let fake = FakeProvider(common: common,
                                base: ["hub/src/lib.rs": "pub struct Thing;\npub fn helper() {}\n"],
                                head: ["hub/src/lib.rs": "pub struct Thing;\npub fn helper() {}\npub fn more() {}\n"])
        let started = ContinuousClock.now
        let graph = await buildGraph(fake)
        let elapsed = ContinuousClock.now - started
        XCTAssertEqual(graph.links.count, 300)
        XCTAssertTrue(graph.links.allSatisfy { $0.to == "hub/src/lib.rs" && $0.state == .kept })
        XCTAssertEqual(graph.links.first?.names, ["Thing", "helper"])
        XCTAssertTrue(graph.complete)
        XCTAssertLessThan(elapsed, GraphLimits.standard.budget)
    }
}

/// Reads `fake`, but throws `error` when `path` is read (on `side` only, when
/// given; after cancelling the running task, when `cancelling`).
private struct FailingProvider: SourceProvider {
    let fake: FakeProvider
    let path: String
    let side: SourceSide?
    let error: any Error
    let cancelling: Bool

    init(_ fake: FakeProvider, at path: String, side: SourceSide? = nil, error: any Error,
         cancelling: Bool = false) {
        self.fake = fake
        self.path = path
        self.side = side
        self.error = error
        self.cancelling = cancelling
    }

    func files(_ side: SourceSide) async throws -> [String] { try await fake.files(side) }

    func text(_ path: String, _ side: SourceSide) async throws -> String? {
        if path == self.path && (self.side ?? side) == side {
            if cancelling { withUnsafeCurrentTask { $0?.cancel() } }
            throw error
        }
        return try await fake.text(path, side)
    }

    func filesMentioning(_ words: [String]) async throws -> [String] { try await fake.filesMentioning(words) }
}

/// Reads `fake` and logs every call; cancels the running task in the first
/// `filesMentioning` when `cancelOnMentioning`.
private final class SpyProvider: SourceProvider, @unchecked Sendable {
    let fake: FakeProvider
    var cancelOnMentioning = false
    private let lock = NSLock()
    private var log: [String] = []

    init(_ fake: FakeProvider) { self.fake = fake }

    /// `files head`, `text a.ts`, `filesMentioning w1 w2`, … in call order.
    var calls: [String] { lock.withLock { log } }

    private func record(_ call: String) { lock.withLock { log.append(call) } }

    func files(_ side: SourceSide) async throws -> [String] {
        record("files \(side)")
        return try await fake.files(side)
    }

    func text(_ path: String, _ side: SourceSide) async throws -> String? {
        record("text \(path)")
        return try await fake.text(path, side)
    }

    func filesMentioning(_ words: [String]) async throws -> [String] {
        record("filesMentioning " + words.joined(separator: " "))
        if cancelOnMentioning { withUnsafeCurrentTask { $0?.cancel() } }
        return try await fake.filesMentioning(words)
    }
}

/// `.stub` files: every one references `core.stub`, which is found by the
/// plain word `plainword` anywhere and by the scoped word `broadword` in the
/// whole repository.
private struct CappedStubLanguage: SourceLanguage {
    let id = "stub"

    func owns(_ path: String) -> Bool { path.hasSuffix(".stub") }

    func parse(_ text: String) -> ParsedSource {
        ParsedSource(referenceLines: [1], wordLines: [:], syntax: 0)
    }

    func makeResolver(_ side: SideIndex) -> any ReferenceResolver { CappedStubResolver() }
}

private final class CappedStubResolver: ReferenceResolver {
    func resolve(_ source: ParsedSource, from path: String) async throws -> [Resolution?] {
        [Resolution(target: "core.stub", names: [])]
    }

    func keywords(for path: String) async throws -> [String] { ["plainword"] }

    func scopedKeywords(for path: String) -> [ScopedKeyword] {
        [ScopedKeyword(word: "broadword", within: "")]
    }
}
