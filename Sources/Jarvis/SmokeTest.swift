import Foundation
import JarvisCore

/// `Jarvis --ask "question" [--image file.jpg] [--provider claude|gemini] [--model name]`
/// Sends one request through the real provider and parser, then prints the resulting beats.
enum SmokeTest {
    private static func value(_ flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// `Jarvis --tts "text" [--voice name] [--model name]`: plays text aloud through the real speech path.
    static func runVoice() -> Never {
        guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? Keychain.geminiKey else {
            print("No Gemini key: set GEMINI_API_KEY or save one in Settings.")
            exit(2)
        }
        let config = VoiceConfig.gemini(
            apiKey: key,
            voice: value("--voice") ?? GeminiVoiceWire.defaultVoice,
            model: value("--model") ?? GeminiVoiceWire.defaultModel,
            fallbackIdentifier: ""
        )
        let text = value("--tts") ?? "Hello from Jarvis."
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let start = Date()
                let output = SpeechOutput()
                output.voiceConfig = { config }
                output.onVoiceError = { print("VOICE ERROR: \($0)") }
                output.onDrained = {
                    withExtendedLifetime(output) {}
                    print(String(format: "finished speaking after %.1fs", Date().timeIntervalSince(start)))
                    exit(0)
                }
                output.begin()
                output.enqueue([.say(text)])
                output.finishInput()
            }
        }
        // A real run loop, as in the app, so main-queue work stays on the main thread.
        RunLoop.main.run()
        exit(0)
    }

    /// `Jarvis --act "[OPEN_APP:Calculator]"` runs a real action. `--find-app name` only reports the match.
    static func runAction() -> Never {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let name = value("--find-app") {
                    print(ActionRunner.findApp(name)?.path ?? "no match")
                    exit(0)
                }
                var parser = ResponseParser()
                let beats = parser.feed(value("--act") ?? "") + parser.finish()
                guard case .action(let tag)? = beats.first else {
                    print("Not an action tag.")
                    exit(2)
                }
                Task {
                    let result = await ActionRunner.run(tag)
                    print(result.summary, result.failure.map { "| says: \($0)" } ?? "")
                    exit(0)
                }
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    /// `Jarvis --save-gemini-key` reads a key from stdin, so it stays out of the shell history and process list.
    static func saveKey() -> Never {
        let key = (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, Keychain.setGeminiKey(key) else {
            print("Key not saved.")
            exit(1)
        }
        print("Saved the Gemini key to Keychain.")
        exit(0)
    }

    static func run() -> Never {

        let useGemini = value("--provider") == "gemini"
        let provider: AIProvider
        if useGemini {
            guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? Keychain.geminiKey else {
                print("No Gemini key: set GEMINI_API_KEY or save one in Settings.")
                exit(2)
            }
            provider = GeminiProvider(apiKey: key, model: value("--model") ?? AppSettings.defaultGeminiModel)
        } else {
            provider = ClaudeCodeProvider(model: value("--model") ?? AppSettings.defaultClaudeModel)
        }

        let images = value("--image").flatMap { FileManager.default.contents(atPath: $0) }.map { [$0] } ?? []
        let request = AIRequest(system: Prompt.system, userText: value("--ask") ?? "Say hello.", jpegImages: images)

        Task {
            let start = Date()
            var firstChunk: TimeInterval?
            var parser = ResponseParser()
            do {
                for try await chunk in provider.stream(request) {
                    if firstChunk == nil { firstChunk = Date().timeIntervalSince(start) }
                    parser.feed(chunk).forEach { print($0) }
                }
                parser.finish().forEach { print($0) }
                print(String(format: "first text after %.1fs, finished after %.1fs", firstChunk ?? -1, Date().timeIntervalSince(start)))
                exit(0)
            } catch {
                print("ERROR: \(error.localizedDescription)")
                exit(1)
            }
        }
        dispatchMain()
    }
}
