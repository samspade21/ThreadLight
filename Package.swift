// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ThreadLight",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ThreadLightCore", targets: ["ThreadLightCore"]),
        .executable(name: "ThreadLight", targets: ["ThreadLightApp"]),
        .executable(name: "threadlight-verify", targets: ["ThreadLightVerify"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.17.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        .target(
            name: "ThreadLightCore",
            dependencies: [
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .define("THREADLIGHT_DEVELOPMENT", .when(configuration: .debug)),
            ]
        ),
        .executableTarget(
            name: "ThreadLightApp",
            dependencies: ["ThreadLightCore"],
            exclude: ["Resources"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .define("THREADLIGHT_DEVELOPMENT", .when(configuration: .debug)),
            ]
        ),
        .executableTarget(
            name: "ThreadLightVerify",
            dependencies: ["ThreadLightCore"]
        ),
        .testTarget(
            name: "ThreadLightCoreTests",
            dependencies: ["ThreadLightCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
