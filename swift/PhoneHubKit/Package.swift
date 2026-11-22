// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhoneHubKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PhoneHubKit", targets: ["PhoneHubKit"]),
        .executable(name: "phonehubkit-selftest", targets: ["phonehubkit-selftest"]),
    ],
    targets: [
        .target(name: "PhoneHubKit"),
        .executableTarget(name: "phonehubkit-selftest", dependencies: ["PhoneHubKit"]),
    ]
)
