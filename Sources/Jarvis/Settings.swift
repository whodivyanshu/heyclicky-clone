import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import JarvisCore
import Security
import Speech

enum ProviderChoice: String, CaseIterable, Identifiable {
    case claudeCode, gemini, appleIntelligence
    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeCode: "Claude Code (local login)"
        case .gemini: "Gemini (API key)"
        case .appleIntelligence: "Apple Intelligence"
        }
    }
}

enum VoiceEngine: String, CaseIterable, Identifiable {
    case system, gemini
    var id: String { rawValue }
    var title: String { self == .system ? "Mac voice (free, offline)" : "Gemini voice (natural)" }
}

enum HotkeyChoice: String, CaseIterable, Identifiable {
    case controlOption, controlCommand, optionCommand
    var id: String { rawValue }

    var title: String {
        switch self {
        case .controlOption: "⌃ Control + ⌥ Option"
        case .controlCommand: "⌃ Control + ⌘ Command"
        case .optionCommand: "⌥ Option + ⌘ Command"
        }
    }

    var symbols: String {
        switch self {
        case .controlOption: "⌃⌥"
        case .controlCommand: "⌃⌘"
        case .optionCommand: "⌥⌘"
        }
    }

    var flags: CGEventFlags {
        switch self {
        case .controlOption: [.maskControl, .maskAlternate]
        case .controlCommand: [.maskControl, .maskCommand]
        case .optionCommand: [.maskAlternate, .maskCommand]
        }
    }
}

/// The facts Jarvis keeps between launches, in a private file on this Mac.
final class MemoryStore: ObservableObject {
    @Published private(set) var book: MemoryBook

    private let url: URL

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jarvis", isDirectory: true)
        url = folder.appendingPathComponent("memory.json")
        book = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(MemoryBook.self, from: $0) } ?? MemoryBook()
    }

    var facts: [String] { book.facts }

    func add(_ text: String) -> String? {
        let saved = book.add(text)
        save()
        return saved
    }

    func forget(matching query: String) -> [String] {
        let removed = book.forget(matching: query)
        save()
        return removed
    }

    func remove(_ fact: String) {
        book.remove(fact)
        save()
    }

    func clear() {
        book.clear()
        save()
    }

    private func save() {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(book), (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

final class AppSettings: ObservableObject {
    static let defaultClaudeModel = "sonnet"
    // Measured against a test screenshot: flash-lite pointed at the wrong spot, and older Flash models were slower.
    static let defaultGeminiModel = "gemini-3.8-flash"
    static let onboardedKey = "onboarded"

    let memory = MemoryStore()

    @Published var provider: ProviderChoice { didSet { save(provider.rawValue, "provider") } }
    @Published var hotkey: HotkeyChoice { didSet { save(hotkey.rawValue, "hotkey") } }
    @Published var claudeModel: String { didSet { save(claudeModel, "claudeModel") } }
    @Published var geminiModel: String { didSet { save(geminiModel, "geminiModel") } }
    @Published var appleLocation: AppleModelLocation { didSet { save(appleLocation.rawValue, "appleLocation") } }
    @Published var voiceIdentifier: String { didSet { save(voiceIdentifier, "voice") } }
    @Published var showWhenIdle: Bool { didSet { UserDefaults.standard.set(showWhenIdle, forKey: "showWhenIdle") } }
    @Published var showIslandWhenIdle: Bool { didSet { UserDefaults.standard.set(showIslandWhenIdle, forKey: "showIslandWhenIdle") } }
    /// Lets Jarvis use the keyboard and work through several steps by itself. Off until the user chooses it.
    @Published var controlsMac: Bool { didSet { UserDefaults.standard.set(controlsMac, forKey: "controlsMac") } }
    @Published var voiceEngine: VoiceEngine { didSet { save(voiceEngine.rawValue, "voiceEngine") } }
    @Published var geminiVoice: String { didSet { save(geminiVoice, "geminiVoice") } }
    @Published var geminiVoiceModel: String { didSet { save(geminiVoiceModel, "geminiVoiceModel") } }
    /// Listens and replies in Hindi. Turning it on also selects the deep Gemini voice preset.
    @Published var hindiAssistant: Bool {
        didSet {
            UserDefaults.standard.set(hindiAssistant, forKey: "hindiAssistant")
            if hindiAssistant {
                voiceEngine = .gemini
                geminiVoice = GeminiVoiceWire.hindiAssistantVoice
            }
        }
    }

    var listeningLocale: Locale? { hindiAssistant ? Locale(identifier: "hi-IN") : nil }

    /// This model gets a short prompt and limited actions. See `OnDeviceRules`.
    var usesOnDeviceRules: Bool { provider == .appleIntelligence && appleLocation == .onDevice }

    init() {
        let defaults = UserDefaults.standard
        provider = defaults.string(forKey: "provider").flatMap(ProviderChoice.init) ?? .claudeCode
        hotkey = defaults.string(forKey: "hotkey").flatMap(HotkeyChoice.init) ?? .controlOption
        claudeModel = defaults.string(forKey: "claudeModel") ?? Self.defaultClaudeModel
        geminiModel = defaults.string(forKey: "geminiModel") ?? Self.defaultGeminiModel
        appleLocation = defaults.string(forKey: "appleLocation").flatMap(AppleModelLocation.init) ?? .onDevice
        voiceIdentifier = defaults.string(forKey: "voice") ?? ""
        showWhenIdle = defaults.object(forKey: "showWhenIdle") as? Bool ?? true
        showIslandWhenIdle = defaults.object(forKey: "showIslandWhenIdle") as? Bool ?? true
        controlsMac = defaults.bool(forKey: "controlsMac")
        voiceEngine = defaults.string(forKey: "voiceEngine").flatMap(VoiceEngine.init) ?? (Keychain.geminiKey != nil ? .gemini : .system)
        geminiVoice = defaults.string(forKey: "geminiVoice") ?? GeminiVoiceWire.defaultVoice
        geminiVoiceModel = defaults.string(forKey: "geminiVoiceModel") ?? GeminiVoiceWire.defaultModel
        hindiAssistant = defaults.bool(forKey: "hindiAssistant")
    }

    /// Without a saved key, a Gemini voice selection uses the Mac voice.
    func voiceConfig() -> VoiceConfig {
        // The Mac voice picker only lists the system language, so Hindi needs its own voice here.
        let macVoice = hindiAssistant ? AVSpeechSynthesisVoice(language: "hi-IN")?.identifier ?? voiceIdentifier : voiceIdentifier
        if voiceEngine == .gemini, let key = Keychain.geminiKey, !key.isEmpty {
            return .gemini(
                apiKey: key,
                voice: geminiVoice,
                model: geminiVoiceModel,
                style: hindiAssistant ? GeminiVoiceWire.hindiAssistantStyle : GeminiVoiceWire.defaultStyle,
                assistantEffect: hindiAssistant,
                fallbackIdentifier: macVoice
            )
        }
        return .system(identifier: macVoice)
    }

    private func save(_ value: String, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    func makeProvider() throws -> AIProvider {
        switch provider {
        case .claudeCode:
            return ClaudeCodeProvider(model: claudeModel)
        case .gemini:
            guard let key = Keychain.geminiKey, !key.isEmpty else {
                throw JarvisMessage("Add your Gemini API key in Settings first.")
            }
            return GeminiProvider(apiKey: key, model: geminiModel)
        case .appleIntelligence:
            return AppleIntelligenceProvider(location: appleLocation, locale: listeningLocale)
        }
    }
}

struct JarvisMessage: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.jarvis",
        kSecAttrAccount as String: "gemini-api-key",
    ]

    static var geminiKey: String? {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setGeminiKey(_ key: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return true }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

enum Permissions {
    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var speech: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
    static var screen: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func requestSpeech() async -> Bool {
        await withCheckedContinuation { continuation in
            requestSpeechAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// Stays outside any actor: the framework calls back on a background queue.
    private nonisolated static func requestSpeechAuthorization(_ done: @escaping @Sendable (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { done($0 == .authorized) }
    }

    static func requestScreen() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Shows the system prompt, which adds Jarvis to the Accessibility list and links to the toggle.
    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openSettings(for pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
