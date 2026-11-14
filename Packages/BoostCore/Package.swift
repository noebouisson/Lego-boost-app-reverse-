// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BoostCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HubLink", targets: ["HubLink"]),
    ],
    targets: [
        .target(name: "HubLink"),
        .testTarget(name: "HubLinkTests", dependencies: ["HubLink"]),
    ]
)
