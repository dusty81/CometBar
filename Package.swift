// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kvm-utility",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CometKit", targets: ["CometKit"]),
        .executable(name: "comet-cli", targets: ["comet-cli"]),
        .executable(name: "CometBar", targets: ["CometBar"]),
        .executable(name: "kvm-clamshelld", targets: ["kvm-clamshelld"]),
    ],
    targets: [
        .target(
            name: "CometKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "comet-cli",
            dependencies: ["CometKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "CometBar",
            dependencies: ["CometKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "kvm-clamshelld",
            dependencies: ["CometKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CometKitTests",
            dependencies: ["CometKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
