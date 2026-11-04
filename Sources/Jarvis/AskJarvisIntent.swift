import AppIntents

/// Lets Shortcuts and Siri send Jarvis a request, and get its reply back.
struct AskJarvisIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Jarvis"
    static let description = IntentDescription("Asks Jarvis something, as if you'd typed it into the island, and returns the reply.")
    // Jarvis has no window to show, and bringing it forward would open Settings.
    static let openAppWhenRun = false

    @Parameter(title: "Request", requestValueDialog: "What should I ask Jarvis?")
    var request: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Jarvis \(\.$request)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let reply = await IntentBridge.ask(request)
        return .result(value: reply)
    }
}

struct JarvisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskJarvisIntent(),
            phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question"],
            shortTitle: "Ask Jarvis",
            systemImageName: "sparkle"
        )
    }
}
