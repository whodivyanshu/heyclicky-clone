// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Jarvis",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic with no UI or OS-permission dependencies, so it can be unit tested.
        .target(name: "JarvisCore"),
        .executableTarget(name: "Jarvis", dependencies: ["JarvisCore"]),
        .testTarget(name: "JarvisCoreTests", dependencies: ["JarvisCore"]),
    ]
)
