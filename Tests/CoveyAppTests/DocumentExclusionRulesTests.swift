import XCTest
import CoveyKit
@testable import covey

final class DocumentExclusionRulesTests: XCTestCase {
    private func rules(_ text: String) throws -> DocumentExclusionRules {
        try .compile(configuration: .init(global: .init(useBuiltins: false, customRules: text)), projectKey: "p", detected: [])
    }
    func testGlobsRespectPathsDirectoriesAndEscapes() throws {
        let r = try rules("/build/\ntarget/\n**/.yarn/cache/\n*.tmp\nfile?.[a-c]\n\\#notes\n\\!notes\nname\\ ")
        for (path, directory, excluded) in [("build/a.md",false,true),("pkg/build/a.md",false,false),("pkg/target/a.md",false,true),("target",false,false),("pkg/.yarn/cache/a",false,true),("a/b.tmp",false,true),("file1.b",false,true),("file1.z",false,false),("#notes",false,true),("!notes",false,true),("name ",false,true)] {
            XCTAssertEqual(r.decision(path:path,isDirectory:directory).excluded, excluded, path)
        }
    }
    func testNegationMustReopenParentsAndExplainsSource() throws {
        let r = try rules("dist/\n!dist/\ndist/*\n!dist/specs/\nbuild/\n!build/plan.md")
        XCTAssertFalse(r.decision(path:"dist/specs/a.md",isDirectory:false).excluded)
        XCTAssertTrue(r.decision(path:"dist/a.md",isDirectory:false).excluded)
        let d = r.decision(path:"build/plan.md",isDirectory:false)
        XCTAssertTrue(d.excluded)
        XCTAssertEqual(d.excludedAncestor,"build")
        XCTAssertEqual(d.source,.global(line:5))
    }
    func testProjectRulesOverrideGlobalAndBuiltins() throws {
        let c = DocumentExclusionConfiguration(global: .init(customRules:"generated/"), projects:["p":.init(customRules:"!node_modules/\n!generated/")])
        let r = try DocumentExclusionRules.compile(configuration:c, projectKey:"p", detected:[.node])
        XCTAssertFalse(r.decision(path:"node_modules/pkg/README.md",isDirectory:false).excluded)
        XCTAssertFalse(r.decision(path:"generated/a.md",isDirectory:false).excluded)
        XCTAssertFalse(r.decision(path:"docs/a.md",isDirectory:false).excluded)
        XCTAssertTrue(r.decision(path:".git/objects/a",isDirectory:false).excluded)
    }
    func testCommentsAndInvalidRules() throws {
        XCTAssertFalse(try rules("# ignored\n\n").decision(path:"docs/a.md",isDirectory:false).excluded)
        XCTAssertThrowsError(try rules("[broken\ntrailing\\")) { error in
            XCTAssertEqual((error as? DocumentRuleCompileError)?.diagnostics.map(\.line),[1,2])
        }
    }
    func testOptionalBuiltinsAndRuleOverrides() throws {
        var c = DocumentExclusionConfiguration()
        var r = try DocumentExclusionRules.compile(configuration:c,projectKey:"p",detected:[.rust,.python,.node])
        for path in ["dist/a.md",".cargo/config.toml",".codex/a.md",".github/a.md",".yarn/releases/a"] {
            XCTAssertFalse(r.decision(path:path,isDirectory:false).excluded,path)
        }
        for path in ["target/a",".venv/a","__pycache__/a","__pypackages__/a","node_modules/a"] {
            XCTAssertTrue(r.decision(path:path,isDirectory:false).excluded,path)
        }
        c.global.ruleOverrides["dist/"] = true
        c.global.ruleOverrides["target/"] = false
        r = try DocumentExclusionRules.compile(configuration:c,projectKey:"p",detected:[.rust])
        XCTAssertTrue(r.decision(path:"dist/a",isDirectory:false).excluded)
        XCTAssertFalse(r.decision(path:"target/a",isDirectory:false).excluded)
    }
}

final class DocumentPresetsTests: XCTestCase {
    func testManifestDetectionAndMalformedJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        try Data("[package]".utf8).write(to:dir.appendingPathComponent("Cargo.toml"))
        try Data("".utf8).write(to:dir.appendingPathComponent("pyproject.toml"))
        try Data(#"{"dependencies":{"react":"1","next":"1","vue":"1","nuxt":"1"}}"#.utf8).write(to:dir.appendingPathComponent("package.json"))
        let detected = DocumentPresets.detect(directory:dir)
        XCTAssertTrue(detected.isSuperset(of:[.common,.rust,.node,.react,.vue,.python]))
        try Data("bad json".utf8).write(to:dir.appendingPathComponent("package.json"))
        let broken = DocumentPresets.detect(directory:dir)
        XCTAssertTrue(broken.contains(.node))
        XCTAssertFalse(broken.contains(.react))
    }
}
