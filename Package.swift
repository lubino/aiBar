// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "aiBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AiBarCore", targets: ["AiBarCore"]),
        .executable(name: "aiBar", targets: ["AiBarApp"])
    ],
    targets: [
        .target(
            name: "AiBarCore",
            path: "Sources/AiBarCore"
        ),
        .executableTarget(
            name: "AiBarApp",
            dependencies: ["AiBarCore"],
            path: "Sources/AiBarApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("WebKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "AiBarTests",
            dependencies: ["AiBarCore"],
            path: "Tests/AiBarCoreTests"
        )
    ]
)
