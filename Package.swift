// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "covey",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0")
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
        .testTarget(
            name: "CoveyKitTests",
            dependencies: ["CoveyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CoveydCoreTests",
            dependencies: ["CoveydCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
