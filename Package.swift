// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Envy",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4")
    ],
    targets: [
        .target(
            name: "VelocityCore"
        ),
        .executableTarget(
            name: "Envy",
            dependencies: [
                "VelocityCore",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .executableTarget(
            name: "VelocitySelfCheck",
            dependencies: ["VelocityCore"]
        ),
        .executableTarget(
            name: "IconGenerator"
        ),
    ],
    swiftLanguageModes: [.v6]
)
