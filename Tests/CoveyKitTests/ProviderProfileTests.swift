import XCTest
@testable import CoveyKit

final class ProviderProfileTests: XCTestCase {
    func testBuiltinAnthropicInjectsNothing() throws {
        let env = ProviderProfile.anthropic.envTemplate(secret: nil)
        XCTAssertEqual(env, [:])
    }
    func testBuiltinGLMTemplateMatchesCurrentZaiClaudeCodeConfig() {
        let env = ProviderProfile.glm.envTemplate(secret: "KEY")

        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "https://api.z.ai/api/anthropic")
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"], "KEY")
        XCTAssertEqual(env["API_TIMEOUT_MS"], "3000000")
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"])
        XCTAssertNil(env["ANTHROPIC_DEFAULT_SONNET_MODEL"])
        XCTAssertNil(env["ANTHROPIC_DEFAULT_OPUS_MODEL"])
    }
    func testRegistryBuiltinsAnthropicFirst() {
        let regs = ProviderRegistry.load(path: "/nonexistent/covey/config.json")
        XCTAssertEqual(regs.first?.id, "anthropic")
        XCTAssertTrue(regs.contains { $0.id == "glm" })
    }
    func testRegistryConfigOverridesAndAdds() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("covey-cfg-\(UUID().uuidString).json")
        let json = """
        {"defaultProvider":"glm","providers":[
          {"id":"glm","label":"GLM","baseURL":"https://api.z.ai/api/anthropic","auth":"bearer",
           "keychainAccount":"covey.provider.glm","modelSlots":{"sonnet":"glm-4.7"},"extraEnv":{}},
          {"id":"kimi","label":"Kimi","baseURL":"https://api.moonshot.cn/anthropic","auth":"bearer",
           "keychainAccount":"covey.provider.kimi","modelSlots":{},"extraEnv":{}}]}
        """
        try Data(json.utf8).write(to: tmp)
        let regs = ProviderRegistry.load(path: tmp.path)
        // user glm overrides built-in sonnet slot
        let glm = try XCTUnwrap(regs.first { $0.id == "glm" })
        XCTAssertEqual(glm.modelSlots?.sonnet, "glm-4.7")
        // kimi added without code change
        XCTAssertTrue(regs.contains { $0.id == "kimi" })
        // anthropic still first even though defaultProvider is glm
        XCTAssertEqual(regs.first?.id, "anthropic")
        try? FileManager.default.removeItem(at: tmp)
    }
}
