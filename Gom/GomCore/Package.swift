// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GomCore",
    platforms: [.macOS("27.0")],
    products: [.library(name: "GomCore", targets: ["GomCore"])],
    targets: [
        .target(name: "GomCore"),
        .testTarget(name: "GomCoreTests", dependencies: ["GomCore"]),
    ]
)
