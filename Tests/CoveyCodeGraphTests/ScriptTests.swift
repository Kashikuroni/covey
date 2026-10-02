import XCTest
@testable import CoveyCodeGraph

final class ScriptTests: XCTestCase {
    func testJSONWithCommentsAndTrailingCommasParses() {
        let json = JSONC.object("{ // note\n \"a\": [1, 2,], /* x */ \"b\": \"//not a comment\", }")
        XCTAssertEqual(json?["a"] as? [Int], [1, 2])
        XCTAssertEqual(json?["b"] as? String, "//not a comment")
        XCTAssertNil(JSONC.object("[1, 2]"))
    }

    func testParserFindsEveryImportForm() {
        let source = ScriptLanguage().parse("""
        import Default, { a, b as c, type T } from './one'
        import * as ns from "../two"
        import './side-effect'
        import type { U } from './types'
        export { x, y as z } from './three'
        export * from './four'
        export * as five from './five'
        export type { V } from './types'
        const lazy = await import('./lazy')
        const req = require('./req')
        import legacy = require('./legacy')
        import {
          multi,
        } from './multi'
        obj.import('./not')
        const s = "import x from './not-either'"
        export const local = 1
        """)
        let imports = (source.syntax as! ScriptSyntax).imports.map {
            "\($0.specifier) \($0.names.joined(separator: ","))"
        }
        XCTAssertEqual(imports, ["./one Default,a,c,T", "../two ns", "./side-effect ", "./types U",
                                 "./three x,y", "./four *", "./five five", "./types V", "./lazy ", "./req ",
                                 "./legacy legacy", "./multi multi"])
        XCTAssertEqual(source.referenceLines, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 14])
    }

    func testRelativeSpecifiersResolveWithExtensionsIndexAndJsToTs() async {
        let fake = FakeProvider(head: [
            "src/app.tsx": """
            import { Button } from './ui'
            import { api } from './api.js'
            import type { Cfg } from './config'
            import helpers from '../lib/helpers'
            import React from 'react'
            const legacy = require('./legacy')
            """,
            "src/ui/index.ts": "export { Button } from './button'\n",
            "src/ui/button.tsx": "export const Button = 1\n",
            "src/api.ts": "export const api = 1\n",
            "src/config.d.ts": "export type Cfg = {}\n",
            "lib/helpers.mjs": "export default {}\n",
            "src/legacy.cjs": "module.exports = {}\n",
        ])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), [
            "src/app.tsx → lib/helpers.mjs added [helpers]",
            "src/app.tsx → src/api.ts added [api]",
            "src/app.tsx → src/config.d.ts added [Cfg]",
            "src/app.tsx → src/legacy.cjs added",
            "src/app.tsx → src/ui/index.ts added [Button]",
            "src/ui/index.ts → src/ui/button.tsx added [Button]",
        ])
    }

    func testAliasesExtendsAndWorkspacePackagesPerNearestConfig() async {
        let fake = FakeProvider(head: [
            "tsconfig.base.json": """
            { // shared by every app
              "compilerOptions": {
                "baseUrl": ".",
                "paths": { "@shared/*": ["packages/shared/src/*"], }, /* trailing comma above */
              },
            }
            """,
            "apps/web/tsconfig.json": "{ \"extends\": \"../../tsconfig.base\" }",
            "apps/web/src/page.ts": "import { fmt } from '@shared/format'\nimport { fmt as f2 } from '@acme/shared'\n",
            "apps/admin/tsconfig.json": """
            { "compilerOptions": { "baseUrl": "src", "paths": { "~/*": ["*"], "config": ["settings/index.ts"] } } }
            """,
            "apps/admin/src/main.ts": """
            import { Card } from '~/components/card'
            import settings from 'config'
            import { util } from 'lib/util'
            import { fmt } from '@shared/format'
            import { Button } from '@acme/ui'
            import { Icon } from '@acme/ui/icons'
            import { z } from 'zod'
            """,
            "apps/admin/src/components/card.tsx": "export const Card = 1\n",
            "apps/admin/src/settings/index.ts": "export default {}\n",
            "apps/admin/src/lib/util.ts": "export const util = 1\n",
            "packages/ui/package.json": "{ \"name\": \"@acme/ui\", \"main\": \"dist/index.js\" }",
            "packages/ui/src/index.ts": "export const Button = 1\n",
            "packages/ui/icons/index.tsx": "export const Icon = 1\n",
            "packages/shared/package.json": "{ \"name\": \"@acme/shared\", \"exports\": { \".\": \"./src/format.ts\" } }",
            "packages/shared/src/format.ts": "export const fmt = 1\n",
        ])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), [
            "apps/admin/src/main.ts → apps/admin/src/components/card.tsx added [Card]",
            "apps/admin/src/main.ts → apps/admin/src/lib/util.ts added [util]",
            "apps/admin/src/main.ts → apps/admin/src/settings/index.ts added [settings]",
            "apps/admin/src/main.ts → packages/ui/icons/index.tsx added [Icon]",
            "apps/admin/src/main.ts → packages/ui/src/index.ts added [Button]",
            "apps/web/src/page.ts → packages/shared/src/format.ts added [f2, fmt]",
        ])
    }

    func testIncomingByFolderAndPackageNameAndARenamedFileIsBroken() async {
        let fake = FakeProvider(
            common: ["web/app.ts": "import { Button } from './components'\nimport { fmt } from '@acme/shared'\n",
                     "web/legacy.ts": "import { old } from './utils/old'\n",
                     "packages/shared/package.json": "{ \"name\": \"@acme/shared\" }"],
            base: ["web/components/index.ts": "export const Button = 1\n",
                   "packages/shared/src/index.ts": "export const fmt = 1\n",
                   "web/utils/old.ts": "export const old = 1\n"],
            head: ["web/components/index.ts": "export const Button = 2\n",
                   "packages/shared/src/index.ts": "export const fmt = 2\n",
                   "web/utils/new.ts": "export const old = 1\n"])
        let graph = await buildGraph(fake, renames: ["web/utils/old.ts": "web/utils/new.ts"])
        XCTAssertEqual(describe(graph), [
            "web/app.ts → packages/shared/src/index.ts kept [fmt]",
            "web/app.ts → web/components/index.ts kept [Button]",
            "web/legacy.ts → web/utils/new.ts broken [old]",
        ])
    }

    /// `import … from '.'`, `from '..'` and `require('..')` reach a folder's
    /// `index.*` without naming the folder, so the folder-name keyword never
    /// finds those files: a changed `index.*` finds them by the scoped
    /// keywords `from` and `require` inside its folder, and only there.
    func testIndexChangeFindsUnchangedFilesInsideItsFolderThatImportDot() async {
        let fake = FakeProvider(
            common: ["src/api/client.ts": "import { x } from '.'\n",
                     "src/api/sub/deep.ts": "import { y } from '..'\n",
                     "src/api/sub/legacy.js": "const client = require('..')\n",
                     "src/other/index.ts": "export const z = 1\n",
                     "src/other/page.ts": "import { z } from '.'\nconst c = require('.')\n"],
            base: ["src/api/index.ts": "export const x = 1\nexport const y = 1\n"],
            head: ["src/api/index.ts": "export const x = 2\nexport const y = 2\n"])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), [
            "src/api/client.ts → src/api/index.ts kept [x]",
            "src/api/sub/deep.ts → src/api/index.ts kept [y]",
            "src/api/sub/legacy.js → src/api/index.ts kept",
        ])
        XCTAssertFalse(fake.readPaths(.head).contains("src/other/page.ts"))
    }

    /// `'.'`, `'..'` and `'dir/'` name a directory, as in Node and TypeScript:
    /// a sibling `src/api.ts` is not `src/api`, only `src/api/index.*` is.
    func testDotDotDotAndTrailingSlashSpecifiersResolveToTheFoldersIndexNotASiblingFile() async {
        let fake = FakeProvider(
            common: ["src/api/client.ts": "import { x } from '.'\n",
                     "src/api/sub/deep.ts": "import { y } from '..'\n",
                     "src/app.ts": "import { z } from './api/'\n"],
            base: ["src/api.ts": "export const other = 1\n",
                   "src/api/index.ts": "export const x = 1\n"],
            head: ["src/api.ts": "export const other = 2\n",
                   "src/api/index.ts": "export const x = 2\n"])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), [
            "src/api/client.ts → src/api/index.ts kept [x]",
            "src/api/sub/deep.ts → src/api/index.ts kept [y]",
            "src/app.ts → src/api/index.ts kept [z]",
        ])
    }

    /// The same rule for a bare specifier found through `baseUrl`.
    func testTrailingSlashThroughBaseUrlResolvesToTheFoldersIndex() async {
        let fake = FakeProvider(head: [
            "tsconfig.json": "{ \"compilerOptions\": { \"baseUrl\": \"src\" } }",
            "src/main.ts": "import { a } from 'lib/'\n",
            "src/lib.ts": "export const other = 1\n",
            "src/lib/index.ts": "export const a = 1\n",
        ])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), ["src/main.ts → src/lib/index.ts added [a]"])
    }

    /// An explicit `./api/index` names the file, not the folder: a changed
    /// `index.*` finds such importers. (The folder-name keyword already
    /// reaches them — `'./api/index'` contains the word `api` — so this pins
    /// the plain path; the `index` keyword pins the one below.)
    func testExplicitIndexImportFromOutsideTheFolderIsAnIncomingLink() async {
        let fake = FakeProvider(
            common: ["src/page.ts": "import { x } from './api/index'\n"],
            base: ["src/api/index.ts": "export const x = 1\n"],
            head: ["src/api/index.ts": "export const x = 2\n"])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), ["src/page.ts → src/api/index.ts kept [x]"])
    }

    /// An explicit `'../index'` names the file while saying neither the
    /// folder nor `from`/`require`: only the plain keyword `index` finds it.
    func testExplicitIndexSpecifierWithoutFromOrRequireIsFound() async {
        let fake = FakeProvider(
            common: ["src/api/sub/deep.ts": "import '../index'\n"],
            base: ["src/api/index.ts": "export const x = 1\n"],
            head: ["src/api/index.ts": "export const x = 2\n"])
        let graph = await buildGraph(fake)
        XCTAssertEqual(describe(graph), ["src/api/sub/deep.ts → src/api/index.ts kept"])
    }
}
