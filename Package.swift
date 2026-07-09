// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "covey",
    platforms: [.macOS(.v26)],
    products: [
        // Exported for the XcodeGen app-bundle targets (project.yml);
        // SPM executables/tests keep working without them.
        .library(name: "CoveyKit", targets: ["CoveyKit"]),
        .library(name: "CoveydCore", targets: ["CoveydCore"])
    ],
    dependencies: [
        // Pinned to the post-1.13.0 upstream fix (PR #522): CSI T (scroll-down /
        // SD) collapsed to a single column on the alt screen because Buffer never
        // initialized marginRight and cmdScrollDown read it raw — froze claude's
        // chat centre on slow scroll-up. Not in any tag yet (v1.13.0 predates the
        // merge). Revert to `from: "1.14.0"` once a release ships it.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", revision: "94b63560c55e80876f32cb3ceeeba369b474bb2c")
    ],
    targets: [
        .target(
            name: "CoveyKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CoveydCore",
            dependencies: [
                "CoveyKit",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "coveyd",
            dependencies: ["CoveydCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "covey",
            dependencies: [
                "CoveyKit",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CoveyKitTests",
            dependencies: ["CoveyKit", "CoveydCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CoveyAppTests",
            dependencies: ["covey", "CoveydCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CoveydCoreTests",
            dependencies: [
                "CoveydCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
