// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hypermux",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hypermux", targets: ["Hypermux"]),
        .executable(name: "hypermuxctl", targets: ["hypermuxctl"]),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "vendor/GhosttyKit.xcframework"
        ),
        // Pure model: layouts, workspaces, focus, config, dispatchers. No AppKit.
        .target(
            name: "HypermuxCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // AppKit shell: window, compositor views, animations, libghostty surfaces.
        .executableTarget(
            name: "Hypermux",
            dependencies: ["HypermuxCore", "GhosttyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(
            name: "hypermuxctl",
            dependencies: ["HypermuxCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HypermuxCoreTests",
            dependencies: ["HypermuxCore"]
        ),
    ]
)
