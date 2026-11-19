// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GroshiCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "GroshiCore", targets: ["GroshiCore"])
    ],
    targets: [
        .target(name: "GroshiCore", path: "Sources/GroshiCore"),
        .testTarget(name: "GroshiCoreTests", dependencies: ["GroshiCore"], path: "Tests/GroshiCoreTests")
    ]
)
