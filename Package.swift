// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Plainword",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PlainwordCore", targets: ["PlainwordCore"])
    ],
    targets: [
        .target(
            name: "PlainwordCore",
            path: "Sources/PlainwordCore",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "PlainwordCoreTests",
            dependencies: ["PlainwordCore"],
            path: "Tests/PlainwordCoreTests"
        )
    ]
)
