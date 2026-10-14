// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VPNNavigator",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VPNNavigatorCore", targets: ["VPNNavigatorCore"]),
        .executable(name: "VPNNavigatorApp", targets: ["VPNNavigatorApp"]),
        .executable(name: "VPNNavigatorHelper", targets: ["VPNNavigatorHelper"])
    ],
    targets: [
        .target(name: "VPNNavigatorCore"),
        .executableTarget(name: "VPNNavigatorApp", dependencies: ["VPNNavigatorCore"]),
        .executableTarget(name: "VPNNavigatorHelper", dependencies: ["VPNNavigatorCore"]),
        .testTarget(name: "VPNNavigatorCoreTests", dependencies: ["VPNNavigatorCore"])
    ]
)
