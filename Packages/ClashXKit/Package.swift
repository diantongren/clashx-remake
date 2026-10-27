// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClashXKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MihomoAPI", targets: ["MihomoAPI"]),
        .library(name: "ConfigKit", targets: ["ConfigKit"]),
        .library(name: "HelperProtocol", targets: ["HelperProtocol"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
    ],
    targets: [
        .target(name: "HelperProtocol"),
        .target(name: "ConfigKit", dependencies: ["Yams"], resources: [.process("Resources")]),
        .target(name: "MihomoAPI"),
        .testTarget(name: "ConfigKitTests", dependencies: ["ConfigKit"]),
        .testTarget(name: "MihomoAPITests", dependencies: ["MihomoAPI"]),
    ],
    swiftLanguageModes: [.v6]
)
