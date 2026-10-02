// swift-tools-version: 5.9
// S1 probe for options 1/4: can Martin 3.2.4 build with the current toolchain and hold a real session
// with our ejabberd? macOS only (Martin depends on Combine and Network.framework).
import PackageDescription

let package = Package(
    name: "MartinProbe",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/tigase/Martin.git", exact: "3.2.4"),
    ],
    targets: [
        .executableTarget(name: "martin-probe", dependencies: [.product(name: "Martin", package: "Martin")]),
    ]
)
