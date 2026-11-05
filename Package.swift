// swift-tools-version:5.10
import PackageDescription

// The Mac app needs AppKit and friends. Windows builds only the shared logic and the bridge
// that its C# app calls, which is in `windows/`.
#if os(Windows)
let dependencies: [Package.Dependency] = []
let appTargets: [Target] = []
#else
let dependencies: [Package.Dependency] = [
    // Secure updates for release builds. See scripts/release.sh.
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
]
let appTargets: [Target] = [
    // Only the type definitions for Kokoro's library, which is downloaded and loaded at runtime if chosen.
    .target(name: "CSherpaOnnx"),
    .executableTarget(
        name: "Jarvis",
        dependencies: ["JarvisCore", "CSherpaOnnx", .product(name: "Sparkle", package: "Sparkle")],
        linkerSettings: [.unsafeFlags([
            // Weak, so Jarvis still launches on macOS versions without this framework.
            "-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels",
            // Where the app bundle keeps Sparkle.
            "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        ])]
    ),
]
#endif

let package = Package(
    name: "Jarvis",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JarvisBridge", type: .dynamic, targets: ["JarvisBridge"]),
    ],
    dependencies: dependencies,
    targets: appTargets + [
        // Pure logic with no UI or OS-permission dependencies, so it can be unit tested.
        .target(name: "JarvisCore"),
        // JarvisCore behind a small C API, for the Windows app.
        .target(name: "JarvisBridge", dependencies: ["JarvisCore"]),
        .testTarget(name: "JarvisCoreTests", dependencies: ["JarvisCore"]),
        .testTarget(name: "JarvisBridgeTests", dependencies: ["JarvisBridge"]),
    ]
)
