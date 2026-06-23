// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "covey",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "CoveyKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
       ),
        .executableTarget(
            name: "coveyd",
            swiftSettings: [.swiftLanguageMode(.v5)]
       ),
        .testTarget(
            name: "CoveyKitTests",
            dependencies: ["CoveyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
       )
    ]
)
