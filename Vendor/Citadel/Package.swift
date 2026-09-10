// swift-tools-version: 5.9
import PackageDescription

// Runtime-only copy of Citadel 0.12.1; see README.md for provenance and local fixes.
let package = Package(
    name: "Citadel",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "Citadel", targets: ["Citadel"])],
    dependencies: [
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.2.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(name: "CCitadelBcrypt"),
        .target(name: "Citadel", dependencies: [
            "CCitadelBcrypt",
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
            .product(name: "BigInt", package: "BigInt"),
            .product(name: "Logging", package: "swift-log"),
        ]),
    ]
)
