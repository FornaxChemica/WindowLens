// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WindowLens",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "WindowLens", targets: ["WindowLens"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0")
    ],
    targets: [
        .executableTarget(
            name: "WindowLens",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "WindowLens/Sources",
            resources: [
                .process("../Resources")
            ]
        ),
        .testTarget(
            name: "WindowLensTests",
            dependencies: ["WindowLens"],
            path: "WindowLens/Tests"
        )
    ]
)
