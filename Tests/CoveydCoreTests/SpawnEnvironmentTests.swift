import XCTest
import CoveyKit
@testable import CoveydCore

final class SpawnEnvironmentTests: XCTestCase {
    // The Finder-spawned daemon case: bare system PATH gains the user dirs.
    func testAppendsMissingUserBins() {
        XCTAssertEqual(
            enrichedPATH("/usr/bin:/bin", home: "/Users/u"),
            "/usr/bin:/bin:/Users/u/.local/bin:/opt/homebrew/bin:/usr/local/bin")
    }

    // A dev-shell PATH that already has some entries only gains the rest,
    // keeping its original order (nothing prepended, system bins still win).
    func testKeepsExistingEntriesAndOrder() {
        XCTAssertEqual(
            enrichedPATH("/Users/u/.local/bin:/usr/bin", home: "/Users/u"),
            "/Users/u/.local/bin:/usr/bin:/opt/homebrew/bin:/usr/local/bin")
    }

    func testNilPathBuildsSystemDefaultPlusUserBins() {
        XCTAssertEqual(
            enrichedPATH(nil, home: "/Users/u"),
            "/usr/bin:/bin:/usr/sbin:/sbin:/Users/u/.local/bin:/opt/homebrew/bin:/usr/local/bin")
    }

    func testFullyEnrichedPathIsUntouched() {
        let path = "/usr/bin:/Users/u/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        XCTAssertEqual(enrichedPATH(path, home: "/Users/u"), path)
    }

    // Finder/env -i case: children must still see a truecolor terminal,
    // or TUIs (claude) drop to monochrome.
    func testTerminalEnvDefaultsFillBareEnvironment() {
        let defaults = Dictionary(uniqueKeysWithValues:
            terminalEnvDefaults([:]).map { ($0.key, $0.value) })
        XCTAssertEqual(defaults["TERM"], "xterm-256color")
        XCTAssertEqual(defaults["COLORTERM"], "truecolor")
        XCTAssertEqual(defaults["LANG"], "en_US.UTF-8")
        // NO CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN: inline mode was tried and
        // reverted — every pane resize (split toggles) turned the normal-buffer
        // transcript into reflow mush plus ink redraw duplicates.
        XCTAssertNil(defaults["CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"])
    }

    func testTerminalEnvDefaultsNeverOverrideExisting() {
        let env = ["TERM": "screen", "LANG": "ru_RU.UTF-8"]
        let keys = terminalEnvDefaults(env).map(\.key)
        XCTAssertEqual(keys, ["COLORTERM"])
    }
}
