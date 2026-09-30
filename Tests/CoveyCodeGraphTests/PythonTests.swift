import XCTest
@testable import CoveyCodeGraph

final class PythonTests: XCTestCase {
    func testParserFindsEveryImportFormAnywhereInTheFile() {
        let source = PythonLanguage().parse("""
        import os, pkg.mod as m
        from . import sibling
        from ..parent.mod import (
            Alpha,
            Beta as B,
        )
        from pkg import *
        if TYPE_CHECKING:
            from pkg.types import Hint
        def f():
            import lazy.thing
        raise Error from exc
        x = "from fake import nothing"
        from a \\
            import b
        """)
        let imports = (source.syntax as! PythonSyntax).imports.map {
            "\($0.level)|\($0.module.joined(separator: "."))|\($0.name ?? "-")"
        }
        XCTAssertEqual(imports, ["0|os|-", "0|pkg.mod|-", "1||sibling", "2|parent.mod|Alpha",
                                 "2|parent.mod|Beta", "0|pkg|*", "0|pkg.types|Hint", "0|lazy.thing|-", "0|a|b"])
        XCTAssertEqual(source.referenceLines, [1, 1, 2, 4, 5, 7, 9, 11, 15])
    }

    func testAbsoluteRelativeSubmoduleAndNameImportsResolve() async {
        let fake = FakeProvider(head: [
            "src/shop/__init__.py": "from .cart import Cart\n",
            "src/shop/cart.py": "from . import pricing\nfrom .pricing import total\nfrom shop.util import helper\nimport shop.models\n",
            "src/shop/pricing.py": "def total(): ...\n",
            "src/shop/util/__init__.py": "def helper(): ...\n",
            "src/shop/models.pyi": "class Order: ...\n",
            "app.py": "from shop import cart, Cart\nimport missing.module\n",
        ])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), [
            "app.py → src/shop/__init__.py added [Cart]",
            "app.py → src/shop/cart.py added",
            "src/shop/__init__.py → src/shop/cart.py added [Cart]",
            "src/shop/cart.py → src/shop/models.pyi added",
            "src/shop/cart.py → src/shop/pricing.py added [total]",
            "src/shop/cart.py → src/shop/util/__init__.py added [helper]",
        ])
    }

    func testEachProjectOfAMonorepoResolvesItsOwnPackage() async {
        let fake = FakeProvider(head: [
            "services/api/pyproject.toml": "[project]\nname = \"api\"\n",
            "services/api/app/__init__.py": "",
            "services/api/app/models.py": "class User: ...\n",
            "services/api/app/views.py": "from app.models import User\n",
            "services/worker/setup.py": "from setuptools import setup\n",
            "services/worker/src/app/__init__.py": "",
            "services/worker/src/app/models.py": "class Job: ...\n",
            "services/worker/src/app/jobs.py": "from app import models\n",
        ])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), [
            "services/api/app/views.py → services/api/app/models.py added [User]",
            "services/worker/src/app/jobs.py → services/worker/src/app/models.py added",
        ])
    }

    func testIncomingTypeCheckingImportIsKeptAndARenamedModuleIsBroken() async {
        let fake = FakeProvider(
            common: ["pkg/__init__.py": "",
                     "pkg/report.py": "from typing import TYPE_CHECKING\nif TYPE_CHECKING:\n    from pkg.ledger import Ledger\n",
                     "pkg/stats.py": "from pkg import money\n"],
            base: ["pkg/ledger.py": "class Ledger: ...\n", "pkg/money.py": "def cents(): ...\n"],
            head: ["pkg/ledger.py": "class Ledger:\n    pass\n", "pkg/currency.py": "def cents(): ...\n"])
        let graph = await buildGraph(fake, renames: ["pkg/money.py": "pkg/currency.py"])
        XCTAssertEqual(describe(graph), [
            "pkg/report.py → pkg/ledger.py kept [Ledger]",
            "pkg/stats.py → pkg/currency.py broken",
        ])
        XCTAssertEqual(graph.usages[LinkKey(from: "pkg/stats.py", to: "pkg/currency.py")],
                       [UsageSite(path: "pkg/stats.py", line: 1, text: "from pkg import money")])
    }

    /// `from . import X` names neither the package folder nor the module, so a
    /// changed `__init__.py` finds those files by the scoped keyword `from`
    /// inside its package, and only there.
    func testInitChangeFindsUnchangedFilesInsideThePackageThatImportFromDot() async {
        let fake = FakeProvider(
            common: ["app/pkg/mod.py": "from . import Thing\n",
                     "app/pkg/sub/deep.py": "from .. import Thing\n",
                     "app/other/__init__.py": "",
                     "app/other/mod.py": "from . import Thing\n"],
            base: ["app/pkg/__init__.py": "class Thing: ...\n"],
            head: ["app/pkg/__init__.py": "class Thing: ...\nclass More: ...\n"])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), [
            "app/pkg/mod.py → app/pkg/__init__.py kept [Thing]",
            "app/pkg/sub/deep.py → app/pkg/__init__.py kept [Thing]",
        ])
        XCTAssertFalse(fake.readPaths(.head).contains("app/other/mod.py"))
    }

    /// A test file sits in its project but outside the project's `src/`: it
    /// still resolves in that project, never in a sibling project.
    func testFileOutsideItsProjectsSrcStillResolvesInItsOwnProject() async {
        let fake = FakeProvider(head: [
            "services/api/pyproject.toml": "[project]\nname = \"api\"\n",
            "services/api/app/__init__.py": "",
            "services/api/app/models.py": "class User: ...\n",
            "services/worker/setup.py": "from setuptools import setup\n",
            "services/worker/src/app/__init__.py": "",
            "services/worker/src/app/models.py": "class Job: ...\n",
            "services/worker/tests/test_jobs.py": "from app.models import Job\n",
        ])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), [
            "services/worker/tests/test_jobs.py → services/worker/src/app/models.py added [Job]",
        ])
    }

    /// Within one project the deeper root wins: `proj/src` before `proj`, also
    /// for a file of the project that is not under `src/`.
    func testDeeperSearchRootOfTheOwnProjectWins() async {
        let fake = FakeProvider(head: [
            "proj/pyproject.toml": "[project]\nname = \"proj\"\n",
            "proj/utils.py": "def top(): ...\n",
            "proj/src/utils.py": "def deep(): ...\n",
            "proj/src/pkg/__init__.py": "",
            "proj/src/pkg/run.py": "import utils\n",
            "proj/tests/test_utils.py": "import utils\n",
        ])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), [
            "proj/src/pkg/run.py → proj/src/utils.py added",
            "proj/tests/test_utils.py → proj/src/utils.py added",
        ])
    }

    /// A file that belongs to no sub-project tries the repository root first,
    /// then every project's roots.
    func testFileOutsideEveryProjectFallsBackToAllRoots() async {
        let fake = FakeProvider(head: [
            "services/api/pyproject.toml": "[project]\nname = \"api\"\n",
            "services/api/app/__init__.py": "",
            "services/api/app/models.py": "class User: ...\n",
            "tools/check.py": "import app.models\n",
            "models.py": "class Local: ...\n",
            "tools/local.py": "import models\n",
        ])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), [
            "tools/check.py → services/api/app/models.py added",
            "tools/local.py → models.py added",
        ])
    }

    func testRelativeImportClimbingAboveTheRepositoryRootHasNoLink() async {
        let fake = FakeProvider(head: [
            "__init__.py": "",
            "x.py": "def f(): ...\n",
            "a.py": "from .. import x\nfrom ..x import f\n",
        ])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), [])
    }
}
