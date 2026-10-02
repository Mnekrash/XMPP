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
        .library(name: "AppSecurity", targets: ["AppSecurity"]),
        .library(name: "XMPPTransport", targets: ["XMPPTransport"]),
        .library(name: "Authentication", targets: ["Authentication"]),
        .library(name: "UI", targets: ["UI"]),
    ],
    dependencies: [
        // XMPP transport candidate (D3). AGPL-3.0: development use only until the licence decision.
        .package(url: "https://github.com/tigase/Martin.git", exact: "3.2.4"),
    ],
    targets: [
        // Pure Swift: models and service/infrastructure protocols. No I/O.
        .target(name: "Domain"),

        // Infrastructure leaf modules.
        .target(name: "AppSecurity", dependencies: ["Domain"]),
        .target(name: "Networking", dependencies: ["Domain"]),
        .target(name: "Persistence", dependencies: ["Domain"]),          // GRDB is added in Phase 1

        // Adapters around open decisions D3/D4: only these may import the chosen libraries.
        .target(
            name: "XMPPTransport",
            dependencies: ["Domain", "Networking", .product(name: "Martin", package: "Martin")],
            swiftSettings: [.swiftLanguageMode(.v5)]   // Martin is a Swift 5 (Combine-based) library
        ),
        .target(name: "OMEMO", dependencies: ["Domain", "AppSecurity"]),

        // Application services.
        .target(name: "SyncEngine", dependencies: ["Domain", "Persistence"]),
        .target(name: "Messaging", dependencies: ["Domain", "Persistence", "SyncEngine"]),
        .target(name: "Attachments", dependencies: ["Domain", "AppSecurity", "Networking"]),
        .target(name: "Push", dependencies: ["Domain"]),
        .target(name: "Authentication", dependencies: ["Domain", "AppSecurity", "XMPPTransport"]),

        // Presentation: depends on Domain only.
        .target(name: "DesignSystem"),
        .target(name: "UI", dependencies: ["Domain", "DesignSystem"]),

        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        .testTarget(name: "NetworkingTests", dependencies: ["Networking"]),
        .testTarget(name: "AuthenticationTests", dependencies: ["Authentication", "AppSecurity"]),
        .testTarget(name: "AppSecurityTests", dependencies: ["AppSecurity"]),
        .testTarget(name: "IntegrationTests", dependencies: ["Authentication", "AppSecurity", "XMPPTransport", "Networking", "Domain"]),
        .testTarget(
            name: "XMPPTransportTests",
            dependencies: ["XMPPTransport", .product(name: "Martin", package: "Martin")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
