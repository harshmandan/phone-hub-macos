// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhoneHubKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhoneHubKit", targets: ["PhoneHubKit"]),
        .executable(name: "phonehubkit-selftest", targets: ["phonehubkit-selftest"]),
        .executable(name: "PhoneHubMenuBar", targets: ["PhoneHubMenuBar"]),
    ],
    targets: [
        .target(name: "PhoneHubKit",
                linkerSettings: [.linkedFramework("IOBluetooth")]),
        .executableTarget(name: "phonehubkit-selftest", dependencies: ["PhoneHubKit"]),
        // The menu-bar app (SwiftUI). Bundled into PhoneHub.app by scripts/app.sh.
        .executableTarget(name: "PhoneHubMenuBar", dependencies: ["PhoneHubKit"],
                          linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("AppKit")]),
    ]
)
