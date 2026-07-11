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
            name: "EnvyCore"
        ),
        .executableTarget(
            name: "Envy",
            dependencies: [
                "EnvyCore",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .executableTarget(
            name: "VelocitySelfCheck",
            dependencies: ["EnvyCore"]
        ),
        .executableTarget(
            name: "IconGenerator"
        ),
    ],
    swiftLanguageModes: [.v6]
)
