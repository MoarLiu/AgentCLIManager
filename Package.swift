// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentCLIManager",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ACMCore", targets: ["ACMCore"]),
        .executable(name: "acm", targets: ["acm"]),
    ],
    targets: [
        .target(
            name: "ACMCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "acm",
            dependencies: ["ACMCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AgentCLIManager",
            dependencies: ["ACMCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AgentCLIManagerTests",
            dependencies: ["AgentCLIManager", "ACMCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ACMCoreTests",
            dependencies: ["ACMCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
