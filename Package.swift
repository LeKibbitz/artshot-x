// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArtShotX",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ArtShotX", targets: ["ArtShotX"])],
    targets: [
        .target(name: "ArtShotCore"),
        .executableTarget(name: "ArtShotX", dependencies: ["ArtShotCore"]),
        .testTarget(name: "ArtShotCoreTests", dependencies: ["ArtShotCore"]),
    ],
    swiftLanguageModes: [.v5]
)
