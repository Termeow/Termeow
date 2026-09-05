// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TermeowKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "TermeowKit", targets: ["TermeowKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.19.0"),
    ],
    targets: [
        .target(
            name: "TermeowKit",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(
            name: "TermeowKitTests",
            dependencies: ["TermeowKit"]
        ),
    ]
)
