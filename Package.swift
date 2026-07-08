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
        .testTarget(
            name: "VelocityTests",
            dependencies: ["VelocityCore"],
            swiftSettings: [
                .unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
