// swift-tools-version: 6.0
// S4 spike: canonical message identity + ingest pipeline (effectively-once visible delivery) on GRDB/SQLite.
import PackageDescription

let package = Package(
    name: "SyncSpike",
    platforms: [.iOS(.v18), .macOS(.v15)],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")],
    targets: [
        .target(name: "SyncCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "sync-cli", dependencies: ["SyncCore"]),
        .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore"]),
    ]
)
