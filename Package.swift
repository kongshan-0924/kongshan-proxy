// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kongshan",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KongshanCore", targets: ["KongshanCore"]),
        .executable(name: "kongshan", targets: ["kongshan"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2")
    ],
    targets: [
        .target(
            name: "KongshanCore",
            dependencies: [.product(name: "Yams", package: "Yams")]
        ),
        .executableTarget(name: "kongshan", dependencies: ["KongshanCore"]),
        .testTarget(name: "KongshanCoreTests", dependencies: ["KongshanCore"]),
        .testTarget(name: "KongshanAppTests", dependencies: ["kongshan", "KongshanCore"])
    ]
)
