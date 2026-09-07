import XCTest
@testable import CoveyKit

final class ProviderProfileTests: XCTestCase {
    func testBuiltinAnthropicInjectsNothing() throws {
        let env = ProviderProfile.anthropic.envTemplate(secret: nil)
        XCTAssertEqual(env, [:])
    }
    func testRegistryBuiltinsAnthropicFirst() {
        let regs = ProviderRegistry.load(path: "/nonexistent/covey/config.json")
        XCTAssertEqual(regs.first?.id, "anthropic")
        XCTAssertEqual(regs.map(\.id), ["anthropic"])
    }
    func testRegistryConfigOverridesAndAdds() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("covey-cfg-\(UUID().uuidString).json")
        let json = """
        {"defaultProvider":"custom","providers":[
          {"id":"custom","label":"Custom","baseURL":"https://provider.example/anthropic","auth":"bearer",
           "keychainAccount":"covey.provider.custom","modelSlots":{"sonnet":"custom-model"},"extraEnv":{}},
          {"id":"kimi","label":"Kimi","baseURL":"https://api.moonshot.cn/anthropic","auth":"bearer",
           "keychainAccount":"covey.provider.kimi","modelSlots":{},"extraEnv":{}}]}
        """
        try Data(json.utf8).write(to: tmp)
        let regs = ProviderRegistry.load(path: tmp.path)
        // custom provider carries its configured model slot
        let custom = try XCTUnwrap(regs.first { $0.id == "custom" })
        XCTAssertEqual(custom.modelSlots?.sonnet, "custom-model")
        // kimi added without code change
        XCTAssertTrue(regs.contains { $0.id == "kimi" })
        // anthropic still first even though defaultProvider is custom
        XCTAssertEqual(regs.first?.id, "anthropic")
        try? FileManager.default.removeItem(at: tmp)
    }
}
