// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LAD",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LAD", targets: ["LAD"]),
        .executable(name: "LADThumbnailExtension", targets: ["LADThumbnailExtension"])
    ],
    targets: [
        .executableTarget(name: "LAD", resources: [.copy("Resources")]),
        .target(name: "LADThumbnailSupport", swiftSettings: [.unsafeFlags(["-application-extension"])]),
        .executableTarget(
            name: "LADThumbnailExtension",
            dependencies: ["LADThumbnailSupport"],
            swiftSettings: [.unsafeFlags(["-parse-as-library", "-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .testTarget(name: "LADTests", dependencies: ["LAD"]),
        .testTarget(name: "LADThumbnailSupportTests", dependencies: ["LADThumbnailSupport"])
    ]
)
