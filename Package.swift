// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "screenshot-describer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "screenshot-describer", targets: ["screenshot-describer"])
    ],
    targets: [
        .executableTarget(
            name: "screenshot-describer"
        )
    ]
)
