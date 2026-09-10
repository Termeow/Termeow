// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TermeowKit",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "TermeowKit", targets: ["TermeowKit"]),
    ],
    dependencies: [
        // Keep the agent handshake/forwarding fixes reproducible in clean builds.
        .package(path: "Vendor/Citadel"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.19.0"),
    ],
    targets: [
        .target(
            name: "TermeowKit",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "TermeowKitTests",
            dependencies: ["TermeowKit"]
        ),
    ]
)
