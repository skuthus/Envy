// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Envy",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .target(
            name: "VelocityCore"
        ),
        .executableTarget(
            name: "Envy",
            dependencies: ["VelocityCore"]
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
