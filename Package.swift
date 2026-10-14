// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VPNNavigator",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VPNNavigatorCore", targets: ["VPNNavigatorCore"]),
        .executable(name: "VPNNavigatorApp", targets: ["VPNNavigatorApp"])
    ],
    targets: [
        .target(name: "VPNNavigatorCore"),
        .executableTarget(name: "VPNNavigatorApp", dependencies: ["VPNNavigatorCore"]),
        .testTarget(name: "VPNNavigatorCoreTests", dependencies: ["VPNNavigatorCore"])
    ]
)
