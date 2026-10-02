// swift-tools-version: 6.0
// Notification Service Extension logic (docs/04 §2): open the gateway's encrypted envelope and decide the
// notification content, falling back to the generic "New message". Platform-neutral so it is testable on Linux;
// on Apple platforms swift-crypto's `Crypto` re-exports CryptoKit.
import PackageDescription

let package = Package(
    name: "NotificationEnvelope",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "NotificationEnvelope", targets: ["NotificationEnvelope"])],
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "6.0.0")],
    targets: [
        .target(name: "NotificationEnvelope", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
        .testTarget(name: "NotificationEnvelopeTests", dependencies: ["NotificationEnvelope"],
                    resources: [.copy("gateway-vectors.json")]),
    ]
)
