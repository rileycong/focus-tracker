// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SyncCore",
    products: [
        .library(name: "SyncCore", targets: ["SyncCore"])
    ],
    targets: [
        .target(name: "SyncCore"),
        .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore"])
    ]
)
