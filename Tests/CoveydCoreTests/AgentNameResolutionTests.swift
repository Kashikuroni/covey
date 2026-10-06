import XCTest
import Foundation
import CoveyKit
@testable import CoveydCore

/// Имена/identity агентов: внешний агент — путь проекта из снятого `cwd`
/// транскрипта (тильда, без префикса), не slug каталога; identity переживает
/// декорирование, чтобы строки таблицы не схлопывались по имени.
final class AgentNameResolutionTests: XCTestCase {
    private func agent(_ name: String, _ id: String? = nil) -> GLMAgentForecast {
        GLMAgentForecast(name: name, id: id, external: false, active: true, isSidechainMarked: false,
                         tokensPerHour: 1, creditsPerHour: 1, sharePercent: 1, budgetMinutes: nil)
    }

    func testExternalAgentGetsTildePathFromCapturedCWD() {
        let agents = [agent("uuid-1", "uuid-1")]   // id ставит движок — декорирование сохраняет
        let offsets = ["/home/.claude/projects/-Users-x-proj/uuid-1.jsonl": UInt64(10)]
        let cwds = ["-Users-x-proj": NSHomeDirectory() + "/proj"]
        let out = UsageMonitor.resolvedAgentNames(agents, sessions: [], offsets: offsets, cwds: cwds)
        XCTAssertEqual(out[0].name, "~/proj")
        XCTAssertTrue(out[0].external)
        XCTAssertEqual(out[0].id, "uuid-1", "identity переживает декорирование")
    }

    func testExternalAgentOutsideHomeKeepsAbsolutePath() {
        let agents = [agent("uuid-1")]
        let offsets = ["/home/.claude/projects/-Users-x-proj/uuid-1.jsonl": UInt64(10)]
        let cwds = ["-Users-x-proj": "/Volumes/work/proj"]
        let out = UsageMonitor.resolvedAgentNames(agents, sessions: [], offsets: offsets, cwds: cwds)
        XCTAssertEqual(out[0].name, "/Volumes/work/proj")
    }

    func testExternalAgentWithoutCWDFallsBackToSlug() {
        let agents = [agent("uuid-1")]
        let offsets = ["/home/.claude/projects/-Users-x-proj/uuid-1.jsonl": UInt64(10)]
        let out = UsageMonitor.resolvedAgentNames(agents, sessions: [], offsets: offsets, cwds: [:])
        XCTAssertEqual(out[0].name, "ext:-Users-x-proj")
        XCTAssertTrue(out[0].external)
    }

    func testCoveySessionKeepsItsName() {
        let agents = [agent("uuid-1")]
        let out = UsageMonitor.resolvedAgentNames(agents, sessions: [("uuid-1", "fix-auth")],
                                                  offsets: [:], cwds: [:])
        XCTAssertEqual(out[0].name, "fix-auth")
        XCTAssertFalse(out[0].external)
    }

    func testBuildTagsAgentsWithSessionKeyID() {
        let agg = TokenAggregator()
        agg.ingest(TokenEvent(t: Date(), sessionKey: "uuid-1", model: "glm-4.6", isSidechain: false,
                              input: 100, output: 0, cacheCreation: 0, cacheRead: 0))
        let (forecast, _) = ForecastEngine.build(
            fiveHours: nil, weekly: nil, aggregator: agg, store: QuotaSampleStore(path: nil),
            factors: CalibrationFactors(), now: Date(), config: GLMForecastConfig())
        XCTAssertEqual(forecast.agents.first?.id, "uuid-1",
                       "identity = ключ сессии, ставится в движке до декорирования")
    }

    func testSameProjectSessionsKeepDistinctIdentity() {
        let agents = [agent("uuid-1", "uuid-1"), agent("uuid-2", "uuid-2")]
        let offsets = ["/p/-Users-x-proj/uuid-1.jsonl": UInt64(1),
                       "/p/-Users-x-proj/uuid-2.jsonl": UInt64(1)]
        let cwds = ["-Users-x-proj": NSHomeDirectory() + "/proj"]
        let out = UsageMonitor.resolvedAgentNames(agents, sessions: [], offsets: offsets, cwds: cwds)
        XCTAssertEqual(out[0].name, out[1].name, "проект один — имя совпадает")
        XCTAssertNotEqual(out[0].stableID, out[1].stableID, "identity разные — строки не схлопываются")
    }
}
