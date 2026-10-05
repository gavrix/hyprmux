// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hyprmux",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hyprmux", targets: ["Hyprmux"]),
        .executable(name: "hyprmuxctl", targets: ["hyprmuxctl"]),
        .executable(name: "hyprmux-tour", targets: ["hyprmux-tour"]),
        .executable(name: "HyprmuxHelper", targets: ["HyprmuxHelper"]),
        .executable(name: "hyprmux-broker", targets: ["hyprmux-broker"]),
        .executable(name: "hyprmux-demo-client", targets: ["hyprmux-demo-client"]),
        .executable(name: "hyprmux-electron-bridge", targets: ["hyprmux-electron-bridge"]),
        .executable(name: "hyprmux-mobile", targets: ["hyprmux-mobile"]),
        .executable(name: "hyprmux-credential-1password", targets: ["hyprmux-credential-1password"]),
        .library(name: "HyprmuxClientKit", targets: ["HyprmuxClientKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", exact: "1.27.6"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
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
            dependencies: ["HyprmuxCore", "HyprmuxCredentialSupport", "GhosttyKit", "ChromiumBridge",
                           "HyprmuxClientProtocol"],
            exclude: ["Credentials"],
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
        // Client protocol (docs/CLIENT_PROTOCOL.md): shared names, the broker, the Swift
        // client kit, and a demo client.
        .target(
            name: "HyprmuxClientProtocol",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "hyprmux-broker",
            dependencies: ["HyprmuxClientProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "HyprmuxClientKit",
            dependencies: ["HyprmuxClientProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOSurface")]
        ),
        .executableTarget(
            name: "hyprmux-electron-bridge",
            dependencies: ["HyprmuxClientKit"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOSurface")]
        ),
        // Mobile.hmapp (Resources/apps): iOS Simulators and Android Emulators as client
        // windows, one process for every device.
        .executableTarget(
            name: "hyprmux-mobile",
            dependencies: ["HyprmuxClientKit", "SimulatorBridge", "AndroidEmulatorBridge"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOSurface"), .linkedFramework("Accelerate")]
        ),
        .target(
            name: "HyprmuxCredentialSupport",
            dependencies: ["HyprmuxCore"],
            path: "Sources/Hyprmux/Credentials",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "OnePasswordCredentialProvider",
            dependencies: ["HyprmuxCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "hyprmux-credential-1password",
            dependencies: ["HyprmuxCore", "OnePasswordCredentialProvider"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "hyprmux-demo-client",
            dependencies: ["HyprmuxClientKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "hyprmuxctl",
            dependencies: ["HyprmuxCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The interactive tour (docs/TOUR.md): steps and checks in a tested library,
        // the terminal UI in the executable. It only reads Hyprmux through the socket.
        .target(
            name: "HyprmuxTour",
            dependencies: ["HyprmuxCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "hyprmux-tour",
            dependencies: ["HyprmuxCore", "HyprmuxTour"],
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
        // Android Emulator discovery and its small checked-in gRPC client surface.
        .target(
            name: "AndroidEmulatorBridge",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            exclude: ["Protos"],
            swiftSettings: [.swiftLanguageMode(.v5)]
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
        .testTarget(
            name: "HyprmuxTourTests",
            dependencies: ["HyprmuxCore", "HyprmuxTour"]
        ),
        .testTarget(
            name: "CredentialProviderTests",
            dependencies: ["HyprmuxCore", "HyprmuxCredentialSupport", "OnePasswordCredentialProvider"]
        ),
        .testTarget(
            name: "AndroidEmulatorBridgeTests",
            dependencies: ["AndroidEmulatorBridge"]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
