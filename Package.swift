// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "fruit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "fruit", targets: ["fruit"])
    ],
    targets: [
        .executableTarget(name: "fruit")
    ]
)
