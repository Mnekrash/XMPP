// swift-tools-version: 6.0
// MessengerKit: all application logic. Module boundaries and allowed dependencies
// follow docs/01-system-architecture.md §2.
import PackageDescription

let package = Package(
    name: "MessengerKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15), // lets `swift test` run the platform-neutral modules on macOS CI
    ],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Networking", targets: ["Networking"]),
        .library(name: "UI", targets: ["UI"]),
    ],
    targets: [
        // Pure Swift: models and service/infrastructure protocols. No I/O.
        .target(name: "Domain"),

        // Infrastructure leaf modules.
        .target(name: "AppSecurity", dependencies: ["Domain"]),
        .target(name: "Networking", dependencies: ["Domain"]),
        .target(name: "Persistence", dependencies: ["Domain"]),          // GRDB is added in Phase 1

        // Adapters around open decisions D3/D4: only these may import the chosen libraries.
        .target(name: "XMPPTransport", dependencies: ["Domain", "Networking"]),
        .target(name: "OMEMO", dependencies: ["Domain", "AppSecurity"]),

        // Application services.
        .target(name: "SyncEngine", dependencies: ["Domain", "Persistence"]),
        .target(name: "Messaging", dependencies: ["Domain", "Persistence", "SyncEngine"]),
        .target(name: "Attachments", dependencies: ["Domain", "AppSecurity", "Networking"]),
        .target(name: "Push", dependencies: ["Domain"]),
        .target(name: "Authentication", dependencies: ["Domain", "AppSecurity"]),

        // Presentation: depends on Domain only.
        .target(name: "DesignSystem"),
        .target(name: "UI", dependencies: ["Domain", "DesignSystem"]),

        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        .testTarget(name: "NetworkingTests", dependencies: ["Networking"]),
    ]
)
