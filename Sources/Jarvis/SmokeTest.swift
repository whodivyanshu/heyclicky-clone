import Foundation
import JarvisCore

/// `Jarvis --ask "question" [--image file.jpg] [--provider claude|gemini|apple|apple-cloud|ollama] [--model name] [--full-control] [--hindi]`
/// Sends one request through the real provider and parser, then prints the resulting beats.
enum SmokeTest {
    private static func value(_ flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// `Jarvis --tts "text" [--voice name] [--model name] [--hindi]`: plays text aloud through the real speech path.
    static func runVoice() -> Never {
        let hindi = CommandLine.arguments.contains("--hindi")
        let usesKokoro = CommandLine.arguments.contains("--kokoro")
        let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? Keychain.geminiKey ?? ""
        guard usesKokoro || !key.isEmpty else {
            print("No Gemini key: set GEMINI_API_KEY or save one in Settings.")
            exit(2)
        }
        let config = usesKokoro ? VoiceConfig.kokoro(
            englishVoice: value("--voice").flatMap(Int.init) ?? KokoroCatalog.defaultEnglishVoice,
            hindiVoice: value("--voice").flatMap(Int.init) ?? KokoroCatalog.defaultHindiVoice,
            assistantEffect: false,
            fallbackIdentifier: ""
        ) : VoiceConfig.gemini(
            apiKey: key,
            voice: value("--voice") ?? (hindi ? GeminiVoiceWire.hindiAssistantVoice : GeminiVoiceWire.defaultVoice),
            model: value("--model") ?? GeminiVoiceWire.defaultModel,
            style: hindi ? GeminiVoiceWire.hindiAssistantStyle : GeminiVoiceWire.defaultStyle,
            assistantEffect: hindi,
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
                    if let data = result.data { print(data) }
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
        let hindiLocale = CommandLine.arguments.contains("--hindi") ? Locale(identifier: "hi-IN") : nil
        let provider: AIProvider
        switch value("--provider") {
        case "gemini":
            guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? Keychain.geminiKey else {
                print("No Gemini key: set GEMINI_API_KEY or save one in Settings.")
                exit(2)
            }
            provider = GeminiProvider(apiKey: key, model: value("--model") ?? AppSettings.defaultGeminiModel)
        case "ollama":
            provider = OllamaProvider(model: value("--model") ?? "")
        case "apple":
            provider = AppleIntelligenceProvider(location: .onDevice, locale: hindiLocale)
        case "apple-cloud":
            provider = AppleIntelligenceProvider(location: .privateCloud, locale: hindiLocale)
        default:
            provider = ClaudeCodeProvider(model: value("--model") ?? AppSettings.defaultClaudeModel)
        }

        let ask = value("--ask") ?? "Say hello."
        // The on-device model goes through the same rules as in the app.
        var onDeviceGuard = value("--provider") == "apple" ? OnDeviceGuard(transcript: ask) : nil
        var images = value("--image").flatMap { FileManager.default.contents(atPath: $0) }.map { [$0] } ?? []
        if onDeviceGuard != nil, !OnDeviceRules.needsScreen(ask) { images = [] }
        let system = onDeviceGuard != nil
            ? OnDeviceRules.system(for: ask)
            : Prompt.system(canControlMac: CommandLine.arguments.contains("--full-control"), hindi: CommandLine.arguments.contains("--hindi"))
        let request = AIRequest(system: system, userText: ask, jpegImages: images)

        Task {
            let start = Date()
            var firstChunk: TimeInterval?
            var parser = ResponseParser()
            var raw = ""
            do {
                for try await chunk in provider.stream(request) {
                    if firstChunk == nil { firstChunk = Date().timeIntervalSince(start) }
                    raw += chunk
                    let beats = parser.feed(chunk)
                    (onDeviceGuard?.filter(beats) ?? beats).forEach { print($0) }
                }
                let beats = parser.finish()
                (onDeviceGuard?.filter(beats, final: true) ?? beats).forEach { print($0) }
                if onDeviceGuard != nil { print("model wrote: \(raw)") }
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
