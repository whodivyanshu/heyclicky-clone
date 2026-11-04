// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Jarvis",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Secure updates for release builds. See scripts/release.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Pure logic with no UI or OS-permission dependencies, so it can be unit tested.
        .target(name: "JarvisCore"),
        .executableTarget(
            name: "Jarvis",
            dependencies: ["JarvisCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags([
                // Weak, so Jarvis still launches on macOS versions without this framework.
                "-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels",
                // Where the app bundle keeps Sparkle.
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
            ])]
        ),
        .testTarget(name: "JarvisCoreTests", dependencies: ["JarvisCore"]),
    ]
)
