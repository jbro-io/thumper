// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Thumper",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Thumper", targets: ["Thumper"])],
    targets: [
        .target(name: "CProcessMetrics", publicHeadersPath: "include"),
        .target(name: "ThumperCore", dependencies: ["CProcessMetrics"]),
        .target(name: "ThumperRendering"),
        .executableTarget(name: "Thumper", dependencies: ["ThumperCore", "ThumperRendering"]),
        .testTarget(name: "ThumperCoreTests", dependencies: ["ThumperCore"]),
        .testTarget(name: "ThumperRenderingTests", dependencies: ["ThumperRendering"])
    ]
)
