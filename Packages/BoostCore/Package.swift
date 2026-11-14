// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BoostCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HubLink", targets: ["HubLink"]),
        .library(name: "BlockEngine", targets: ["BlockEngine"]),
        .library(name: "AppCore", targets: ["AppCore"]),
    ],
    targets: [
        .target(name: "HubLink"),
        .target(name: "BlockEngine"),
        .target(name: "AppCore", dependencies: ["HubLink", "BlockEngine"]),
        .testTarget(name: "HubLinkTests", dependencies: ["HubLink"]),
        .testTarget(name: "BlockEngineTests", dependencies: ["BlockEngine"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore"]),
    ]
)
