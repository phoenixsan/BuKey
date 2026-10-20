// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BuKey",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "BuKey",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "BuKeyTests",
            dependencies: ["BuKey"]
        )
    ]
)
