// swift-tools-version: 6.2
// S1 spike: OMEMO 2 (XEP-0384 v0.9.x, urn:xmpp:omemo:2) protocol/state layer prototype.
// All cryptographic primitives come from established libraries:
//   swift-crypto (X25519, Ed25519, HKDF-SHA-256, HMAC-SHA-256, AES-256-CBC via CryptoExtras),
//   libsodium (Ed25519 <-> X25519 key conversion), swift-protobuf (wire format).
import PackageDescription

let package = Package(
    name: "OMEMOSpike",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "OMEMOKit", targets: ["OMEMOKit"]),
        .executable(name: "omemo-cli", targets: ["omemo-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
    ],
    targets: [
        // Linux spike: system libsodium (libsodium-dev). On iOS this would be swift-sodium's bundled build.
        .systemLibrary(name: "Clibsodium", pkgConfig: "libsodium", providers: [.apt(["libsodium-dev"]), .brew(["libsodium"])]),
        .target(
            name: "OMEMOKit",
            dependencies: [
                "Clibsodium",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "CryptoExtras", package: "swift-crypto"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .executableTarget(name: "omemo-cli", dependencies: ["OMEMOKit"]),
        .testTarget(name: "OMEMOKitTests", dependencies: ["OMEMOKit"]),
    ]
)
