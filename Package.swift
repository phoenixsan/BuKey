// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LayoutPilot",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LayoutPilot",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
