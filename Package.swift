// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clocky",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Clocky", targets: ["Clocky"]),
        .library(name: "ClockyCore", targets: ["ClockyCore"])
    ],
    targets: [
        .target(name: "ClockyCore"),
        .executableTarget(name: "Clocky", dependencies: ["ClockyCore"]),
        .testTarget(name: "ClockyCoreTests", dependencies: ["ClockyCore"]),
        .testTarget(name: "ClockyTests", dependencies: ["Clocky", "ClockyCore"])
    ]
)
