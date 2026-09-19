// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kongshan",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KongshanCore", targets: ["KongshanCore"]),
        .executable(name: "kongshan", targets: ["kongshan"]),
        .executable(name: "KongshanHelper", targets: ["KongshanHelper"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2")
    ],
    targets: [
        // App 与 helper 共用的固定协议/常量。无第三方依赖，两边都能引。
        .target(name: "HelperProtocol"),
        .target(
            name: "KongshanCore",
            dependencies: [.product(name: "Yams", package: "Yams"), "HelperProtocol"],
            linkerSettings: [.linkedFramework("SystemConfiguration")]
        ),
        .executableTarget(name: "kongshan", dependencies: ["KongshanCore", "HelperProtocol"]),
        // 特权助手（以 root 运行）。极小、职责单一：起/停内置 sing-box。
        .executableTarget(
            name: "KongshanHelper",
            dependencies: ["HelperProtocol"],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(name: "KongshanCoreTests", dependencies: ["KongshanCore", "HelperProtocol"]),
        .testTarget(name: "KongshanAppTests", dependencies: ["kongshan", "KongshanCore"]),
        .testTarget(name: "HelperProtocolTests", dependencies: ["HelperProtocol"])
    ]
)
