import XCTest
@testable import CoveyCodeGraph

final class RustTests: XCTestCase {
    func testCargoManifestReadsNameLibAndBinPaths() {
        let manifest = CargoManifest.parse("""
        [package]
        name = "acme-api" # the api
        version = "0.1.0"

        [lib]
        path = 'src/api.rs'

        [[bin]]
        name = "srv"
        path = "bin/srv.rs"

        [dependencies]
        name = "not-the-package"
        """)
        XCTAssertEqual(manifest, CargoManifest(packageName: "acme-api", libPath: "src/api.rs",
                                               binPaths: ["bin/srv.rs"]))
        XCTAssertNil(CargoManifest.parse("[workspace]\nmembers = [\"crates/*\"]").packageName)
    }

    func testParserFlattensMultilineUseTreesAndFindsPathsInCode() {
        let source = RustLanguage().parse("""
        use crate::{
            a::{self, B as C},
            d::*,
        };
        use ::ext::X;
        use super::super::y;
        mod tests { use super::*; }
        fn f() { crate::a::go(); std::mem::take(); Self::new(); ::ext::y(); }
        mod m;
        """)
        let syntax = source.syntax as! RustSyntax
        XCTAssertEqual(syntax.paths.map { $0.segments.joined(separator: "::") },
                       ["crate::a", "crate::a::B", "crate::d::*", "ext::X", "super::super::y", "super::*",
                        "crate::a::go", "std::mem::take", "ext::y"])
        XCTAssertEqual(syntax.paths.map(\.global), [false, false, false, true, false, false, false, false, true])
        XCTAssertEqual(syntax.paths.map(\.isUse), [true, true, true, true, true, true, false, false, false])
        XCTAssertEqual(syntax.paths[5].scope, ["tests"])
        XCTAssertEqual(source.referenceLines, [2, 2, 3, 5, 6, 7, 8, 8, 8])
        XCTAssertEqual(syntax.modules, [RustSyntax.Module(path: ["tests"], inline: true),
                                        RustSyntax.Module(path: ["m"], inline: false)])
    }

    func testModuleTreeUseTreesAndCodePathsResolveWithoutModEdges() async {
        let fake = FakeProvider(head: [
            "Cargo.toml": "[package]\nname = \"shop-core\"\n",
            "src/lib.rs": "pub mod net;\nmod billing;\npub mod util { pub mod fmt; }\npub use billing::Invoice;\n",
            "src/net/mod.rs": "pub mod client;\nuse crate::util::fmt::money;\n",
            "src/net/client.rs": """
            use super::super::billing::{self, Invoice as Inv, tax::*};
            use crate::{util::fmt, net};
            pub fn pay() { crate::billing::charge(); }
            #[cfg(test)]
            mod tests { use super::*; }
            """,
            "src/billing.rs": "pub mod tax;\npub struct Invoice;\npub fn charge() {}\n",
            "src/billing/tax.rs": "pub fn rate() {}\n",
            "src/util/fmt.rs": "pub fn money() {}\n",
            "tests/it.rs": "mod common;\nuse common::setup;\nuse shop_core::net::client::pay;\n",
            "tests/common/mod.rs": "pub fn setup() {}\n",
        ])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), [
            "src/lib.rs → src/billing.rs added [Invoice]",
            "src/net/client.rs → src/billing.rs added [Invoice, charge]",
            "src/net/client.rs → src/billing/tax.rs added [*]",
            "src/net/client.rs → src/net/mod.rs added",
            "src/net/client.rs → src/util/fmt.rs added",
            "src/net/mod.rs → src/util/fmt.rs added [money]",
            "tests/it.rs → src/net/client.rs added [pay]",
            "tests/it.rs → tests/common/mod.rs added [setup]",
        ])
        XCTAssertEqual(graph.usages[LinkKey(from: "src/net/client.rs", to: "src/billing.rs")]?.map(\.line), [1, 3])
    }

    /// Two crates with a `service.rs` each: every file resolves in its own crate.
    private let workspace: [String: String] = [
        "Cargo.toml": "[workspace]\nmembers = [\"crates/*\", \"tools\"]\n",
        "crates/core/Cargo.toml": "[package]\nname = \"acme-core\"\n",
        "crates/core/src/lib.rs": "pub mod service;\n",
        "crates/api/Cargo.toml": "[package]\nname = \"acme-api\"\n[lib]\npath = \"src/api.rs\"\n[[bin]]\nname = \"srv\"\npath = \"bin/srv.rs\"\n",
        "crates/api/src/api.rs": "pub mod service;\nuse acme_core::service::Service as Core;\n",
        "crates/api/src/service.rs": "pub fn handle() { crate::service::handle(); }\n",
        "crates/api/bin/srv.rs": "fn main() { acme_api::service::handle(); let _ = ::acme_core::service::Service; }\n",
        "crates/api/tests/smoke.rs": "use acme_api::service;\n",
        "tools/Cargo.toml": "[package]\nname = \"tools\"\n",
        "tools/src/main.rs": "mod service;\nfn main() { service::run(); }\n",
        "tools/src/service.rs": "pub fn run() {}\n",
    ]

    func testWorkspaceCratesResolveInTheirOwnCrate() async {
        let fake = FakeProvider(head: workspace.merging(["crates/core/src/service.rs": "pub struct Service;\n"]) { $1 })
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), [
            "crates/api/bin/srv.rs → crates/api/src/service.rs added [handle]",
            "crates/api/bin/srv.rs → crates/core/src/service.rs added [Service]",
            "crates/api/src/api.rs → crates/core/src/service.rs added [Service]",
            "crates/api/tests/smoke.rs → crates/api/src/service.rs added",
        ])
    }

    func testSameFileNameElsewhereIsFilteredOutOfIncomingLinks() async {
        let fake = FakeProvider(common: workspace,
                                base: ["crates/core/src/service.rs": "pub struct Service;\n"],
                                head: ["crates/core/src/service.rs": "pub struct Service;\npub fn extra() {}\n"])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), [
            "crates/api/bin/srv.rs → crates/core/src/service.rs kept [Service]",
            "crates/api/src/api.rs → crates/core/src/service.rs kept [Service]",
        ])
    }

    func testRenamedModuleLeavesBrokenUsesInUnchangedFiles() async {
        let fake = FakeProvider(
            common: ["Cargo.toml": "[package]\nname = \"app\"\n",
                     "src/report.rs": "use crate::pay::charge;\npub fn run() { charge(); }\n"],
            base: ["src/lib.rs": "pub mod pay;\npub mod report;\n", "src/pay.rs": "pub fn charge() {}\n"],
            head: ["src/lib.rs": "pub mod billing;\npub mod report;\n", "src/billing.rs": "pub fn charge() {}\n"])
        let graph = await buildGraph(fake, renames: ["src/pay.rs": "src/billing.rs"])
        XCTAssertEqual(describe(graph), ["src/report.rs → src/billing.rs broken [charge]"])
        XCTAssertEqual(graph.usages[LinkKey(from: "src/report.rs", to: "src/billing.rs")]?.map(\.line), [1, 2])
    }

    func testRenamedModuleWithUpdatedUseIsKept() async {
        let fake = FakeProvider(
            common: ["Cargo.toml": "[package]\nname = \"app\"\n"],
            base: ["src/lib.rs": "pub mod pay;\npub mod report;\n", "src/pay.rs": "pub fn charge() {}\n",
                   "src/report.rs": "use crate::pay::charge;\n"],
            head: ["src/lib.rs": "pub mod billing;\npub mod report;\n", "src/billing.rs": "pub fn charge() {}\n",
                   "src/report.rs": "use crate::billing::charge;\n"])
        let graph = await buildGraph(fake, renames: ["src/pay.rs": "src/billing.rs"])
        XCTAssertEqual(describe(graph), ["src/report.rs → src/billing.rs kept [charge]"])
    }
}
