// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hyprmux",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hyprmux", targets: ["Hyprmux"]),
        .executable(name: "hyprmuxctl", targets: ["hyprmuxctl"]),
        .executable(name: "HyprmuxHelper", targets: ["HyprmuxHelper"]),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "vendor/GhosttyKit.xcframework"
        ),
        // Pure model: layouts, workspaces, focus, config, dispatchers. No AppKit.
        .target(
            name: "HyprmuxCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // AppKit shell: window, compositor views, animations, libghostty surfaces.
        .executableTarget(
            name: "Hyprmux",
            dependencies: ["HyprmuxCore", "GhosttyKit", "ChromiumBridge", "SimulatorBridge"],
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
            name: "hyprmuxctl",
            dependencies: ["HyprmuxCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // CEF's C++ wrapper (libcef_dll_wrapper), built from the SDK in vendor/cef.
        .target(
            name: "CEFWrapper",
            path: "vendor/cef",
            exclude: ["include", "Release", "LICENSE.txt", "libcef_dll/CMakeLists.txt"],
            sources: ["libcef_dll"],
            publicHeadersPath: "swiftpm-public",
            cxxSettings: [
                .headerSearchPath("."),
                .define("WRAPPING_CEF_SHARED"),
                .unsafeFlags(["-Wno-deprecated-declarations", "-Wno-undefined-var-template"]),
            ]
        ),
        // Objective-C++ bridge: CEF browsers as NSViews, exposed to Swift.
        .target(
            name: "ChromiumBridge",
            dependencies: ["CEFWrapper"],
            cxxSettings: [
                .headerSearchPath("../../vendor/cef"),
                .unsafeFlags(["-fobjc-arc", "-Wno-deprecated-declarations"]),
            ],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // iOS Simulator displays via Xcode's private CoreSimulator/SimulatorKit.
        .target(
            name: "SimulatorBridge",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("IOSurface")]
        ),
        .executableTarget(
            name: "HyprmuxHelper",
            dependencies: ["ChromiumBridge"],
            cSettings: [.unsafeFlags(["-fobjc-arc"])]
        ),
        .testTarget(
            name: "HyprmuxCoreTests",
            dependencies: ["HyprmuxCore"]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
