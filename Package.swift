// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RehireBar",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "RehireBar", targets: ["RehireBar"]),
        .library(name: "AgentStatusCore", targets: ["AgentStatusCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .target(name: "AgentStatusCore"),
        .executableTarget(
            name: "RehireBar",
            dependencies: ["AgentStatusCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "RehireBarTests",
            dependencies: ["RehireBar", "AgentStatusCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
