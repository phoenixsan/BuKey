// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BuKey",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "BuKey",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
