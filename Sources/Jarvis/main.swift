import AppKit

if CommandLine.arguments.contains("--ask") {
    // Terminal check of the AI path. Needs no window or macOS permissions.
    SmokeTest.run()
}
if CommandLine.arguments.contains("--tts") {
    SmokeTest.runVoice()
}
if CommandLine.arguments.contains("--act") || CommandLine.arguments.contains("--find-app") {
    SmokeTest.runAction()
}
if CommandLine.arguments.contains("--save-gemini-key") {
    SmokeTest.saveKey()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // `delegate` is a weak reference on NSApplication, and run() keeps this scope alive.
    withExtendedLifetime(delegate) { app.run() }
}
