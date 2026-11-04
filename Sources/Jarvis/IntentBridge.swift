import Foundation

/// How an intent reaches the running app. The system runs intents inside Jarvis's own process.
@MainActor
enum IntentBridge {
    static var handler: ((String) async -> String)?

    static func ask(_ request: String) async -> String {
        // The app may have only just been launched to run this.
        for _ in 0..<50 where handler == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await handler?(request) ?? "Jarvis isn't ready yet."
    }
}
