// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Mangrove",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "Mangrove", targets: ["Mangrove"])
    ],
    targets: [
        .executableTarget(
            name: "Mangrove",
            path: "Sources/Mangrove"
        ),
        .testTarget(
            name: "MangroveTests",
            dependencies: ["Mangrove"],
            path: "Tests/MangroveTests"
        )
    ]
)
