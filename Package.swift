// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LAD",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LAD", targets: ["LAD"])],
    targets: [
        .executableTarget(name: "LAD", resources: [.copy("Resources")]),
        .testTarget(name: "LADTests", dependencies: ["LAD"])
    ]
)
