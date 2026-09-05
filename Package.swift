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
    targets: [
        .target(name: "AgentStatusCore"),
        .executableTarget(
            name: "RehireBar",
            dependencies: ["AgentStatusCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "RehireBarTests",
            dependencies: ["RehireBar", "AgentStatusCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
