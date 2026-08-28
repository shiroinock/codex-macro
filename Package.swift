// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "keychron-c100-status",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "c100-status", targets: ["C100Status"]),
    ],
    targets: [
        .executableTarget(
            name: "C100Status",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
