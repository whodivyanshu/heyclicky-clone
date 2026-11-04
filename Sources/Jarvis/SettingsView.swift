import AVFoundation
import Combine
import JarvisCore
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case voice = "Voice"
    case ai = "AI"
    case handsFree = "Hands-free"
    case routines = "Routines"
    case meetings = "Meetings"
    case teaching = "Teaching"
    case screenMemory = "Screen memory"
    case memory = "Memory"
    case history = "History"
    case activity = "Activity"
    case safety = "Safety"
    case permissions = "Permissions"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .voice: "waveform"
        case .ai: "sparkle"
        case .handsFree: "ear"
        case .routines: "clock.arrow.2.circlepath"
        case .meetings: "person.2"
        case .teaching: "graduationcap"
        case .screenMemory: "magnifyingglass"
        case .memory: "brain"
        case .history: "text.bubble"
        case .activity: "list.bullet.rectangle"
        case .safety: "hand.raised"
        case .permissions: "lock.shield"
        }
    }
}

enum Palette {
    static let background = Color.black
    static let sidebar = Color(white: 0.055)
    static let card = Color(white: 0.09)
    static let line = Color.white.opacity(0.09)
    static let secondary = Color.white.opacity(0.55)
    static let selected = Color.white.opacity(0.11)
}

struct SettingsView: View {
    static let size = CGSize(width: 780, height: 620)

    @ObservedObject var settings: AppSettings
    @State private var tab: SettingsTab
    @State private var keyDraft = ""
    @State private var hasKey = Keychain.geminiKey != nil
    @State private var testResult = ""
    @State private var isTesting = false
    @State private var previewResult = ""
    @State private var preview = SpeechOutput()
    @State private var micGranted = Permissions.microphone
    @State private var speechGranted = Permissions.speech
    @State private var screenGranted = Permissions.screen
    @State private var accessibilityGranted = Permissions.accessibility
    @State private var calendarGranted = NativeServices.hasCalendar
    @State private var remindersGranted = NativeServices.hasReminders
    @State private var contactsGranted = NativeServices.hasContacts

    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let voices = SpeechOutput.bestVoices()

    init(settings: AppSettings, initialTab: SettingsTab = .general) {
        self.settings = settings
        _tab = State(initialValue: initialTab)
    }

    private var missingPermissions: Int {
        [micGranted, speechGranted, screenGranted].filter { !$0 }.count
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Palette.line).frame(width: 1)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(tab.rawValue)
                        .font(.system(size: 24, weight: .semibold))
                    page
                }
                .padding(.horizontal, 32)
                .padding(.top, 34)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Palette.background)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .onReceive(refresh) { _ in
            micGranted = Permissions.microphone
            speechGranted = Permissions.speech
            screenGranted = Permissions.screen
            accessibilityGranted = Permissions.accessibility
            calendarGranted = NativeServices.hasCalendar
            remindersGranted = NativeServices.hasReminders
            contactsGranted = NativeServices.hasContacts
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 34, height: 34)
                Text("Jarvis")
                    .font(.system(size: 16, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.top, 38)
            .padding(.bottom, 10)

            ForEach(SettingsTab.allCases) { item in
                Button { tab = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13))
                            .frame(width: 18)
                        Text(item.rawValue)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        if item == .permissions, missingPermissions > 0 {
                            Text("\(missingPermissions)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 18, height: 18)
                                .background(.white, in: Circle())
                        }
                    }
                    .foregroundStyle(tab == item ? Color.white : Palette.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 31)
                    .background(tab == item ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(missingPermissions == 0 ? Color.white : Color.white.opacity(0.3))
                    .frame(width: 7, height: 7)
                Text(missingPermissions == 0 ? "Ready" : "Setup needed")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 10)
        .frame(width: 196)
        .frame(maxHeight: .infinity)
        .background(Palette.sidebar)
    }

    // MARK: - Pages

    @ViewBuilder private var page: some View {
        switch tab {
        case .general: generalPage
        case .voice: voicePage
        case .ai: aiPage
        case .handsFree: HandsFreePage(settings: settings)
        case .routines: RoutinesPage(routines: settings.routines)
        case .meetings: MeetingsPage(meetings: settings.meetings, settings: settings)
        case .teaching: TeachingPage(settings: settings)
        case .screenMemory: ScreenMemoryPage(settings: settings, memory: settings.screenMemory)
        case .memory: MemoryPage(memory: settings.memory)
        case .history: HistoryPage(settings: settings, conversations: settings.conversations)
        case .activity: ActivityPage(settings: settings, activity: settings.activity)
        case .safety: SafetyPage(settings: settings)
        case .permissions: permissionsPage
        }
    }

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                howToStep(symbol: "keyboard", title: "Hold \(settings.hotkey.symbols)", detail: "Ask about anything on screen")
                howToStep(symbol: "hand.point.up.left", title: "Let go", detail: "Jarvis answers and points")
                howToStep(symbol: "escape", title: "Press Esc", detail: "Stops it at any time")
            }
            Card {
                Row("Hold to talk") {
                    Picker("", selection: $settings.hotkey) {
                        ForEach(HotkeyChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider().overlay(Palette.line)
                LaunchAtLoginRow()
                Divider().overlay(Palette.line)
                Row("Show the island when idle", detail: "Hover over it to chat or type a question") {
                    Toggle("", isOn: $settings.showIslandWhenIdle)
                        .labelsHidden()
                        .toggleStyle(MonoSwitch())
                }
                Divider().overlay(Palette.line)
                Row("Show the pointer when idle", detail: "The small pointer that follows your cursor") {
                    Toggle("", isOn: $settings.showWhenIdle)
                        .labelsHidden()
                        .toggleStyle(MonoSwitch())
                }
                Divider().overlay(Palette.line)
                Row("Let Jarvis control my Mac", detail: "Finishes whole jobs by itself, and asks you before anything like sending, deleting or paying. Press Esc to stop it") {
                    Toggle("", isOn: $settings.controlsMac)
                        .labelsHidden()
                        .toggleStyle(MonoSwitch())
                }
            }
            Note("Say \"teach me...\" or \"walk me through...\" and Jarvis guides you click by click. It circles each step and moves on when you click it. Without full control, \"how do I...\" does this too.")
        }
    }

    private var voicePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("", selection: $settings.voiceEngine) {
                Text("Gemini voice").tag(VoiceEngine.gemini)
                Text("Mac voice").tag(VoiceEngine.system)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Card {
                Row("Hindi assistant", detail: "Listens and replies in Hindi, with a deep, calm voice") {
                    Toggle("", isOn: $settings.hindiAssistant)
                        .labelsHidden()
                        .toggleStyle(MonoSwitch())
                }
                Divider().overlay(Palette.line)
                switch settings.voiceEngine {
                case .gemini:
                    Row("Voice") {
                        Picker("", selection: $settings.geminiVoice) {
                            ForEach(GeminiVoiceWire.voices, id: \.name) { voice in
                                Text("\(voice.name) (\(voice.style))").tag(voice.name)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Divider().overlay(Palette.line)
                    Row("Voice model") {
                        DarkField(text: $settings.geminiVoiceModel, width: 230)
                    }
                case .system:
                    Row("Voice") {
                        Picker("", selection: $settings.voiceIdentifier) {
                            Text("Best available").tag("")
                            ForEach(voices, id: \.identifier) { voice in
                                Text("\(voice.name) (\(qualityName(voice)))").tag(voice.identifier)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                Divider().overlay(Palette.line)
                Row("Preview", detail: previewResult.isEmpty ? nil : previewResult) {
                    OutlineButton("Play sample", symbol: "play.fill", action: previewVoice)
                }
            }

            Note(settings.voiceEngine == .gemini
                ? "Sounds natural, but takes a few extra seconds to start and is billed to your Gemini key. If a request fails, Jarvis uses the Mac voice for that reply."
                : "Free, works offline and starts right away. Download a Premium voice in System Settings for a much better sound.")
        }
    }

    private var aiPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("", selection: $settings.provider) {
                Text("Claude Code").tag(ProviderChoice.claudeCode)
                Text("Gemini").tag(ProviderChoice.gemini)
                Text("Apple Intelligence").tag(ProviderChoice.appleIntelligence)
                Text("Ollama").tag(ProviderChoice.ollama)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Card {
                switch settings.provider {
                case .claudeCode:
                    Row("Model") {
                        Picker("", selection: $settings.claudeModel) {
                            Text("Sonnet: balanced").tag("sonnet")
                            Text("Haiku: fastest").tag("haiku")
                            Text("Opus: most capable").tag("opus")
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                case .gemini:
                    Row("Model") {
                        DarkField(text: $settings.geminiModel, width: 230)
                    }
                case .appleIntelligence:
                    Row("Runs on", detail: AppleIntelligenceProvider.unavailableReason(settings.appleLocation) ?? "Ready") {
                        Picker("", selection: $settings.appleLocation) {
                            ForEach(AppleModelLocation.allCases) { location in
                                Text(location.title).tag(location)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                case .ollama:
                    OllamaRow(settings: settings)
                }
                if settings.provider == .gemini || settings.voiceEngine == .gemini {
                    Divider().overlay(Palette.line)
                    Row("Gemini API key", detail: hasKey ? "Saved in Keychain" : "Not saved yet") {
                        HStack(spacing: 8) {
                            DarkField(text: $keyDraft, width: 170, isSecure: true, placeholder: hasKey ? "Replace key" : "Paste key")
                            OutlineButton("Save", isEnabled: !keyDraft.isEmpty, action: saveKey)
                        }
                    }
                }
                Divider().overlay(Palette.line)
                Row("Connection", detail: testResult.isEmpty ? nil : testResult) {
                    OutlineButton(isTesting ? "Testing…" : "Test", isEnabled: !isTesting, action: test)
                }
            }

            if settings.provider == .ollama {
                Note("Runs on this Mac, so your screenshots and questions stay here. Pointing and clicking need a model that can read images, and are usually less accurate than the online models.")
            } else if settings.provider == .claudeCode {
                Note("Uses the claude command and your existing login. Requests count toward your Claude plan.")
            } else if settings.provider == .appleIntelligence {
                Note(settings.appleLocation == .onDevice
                    ? "Stays on this Mac. It answers questions, opens and quits apps and websites, finds files and reads your screen when you ask. It can't click, type, point or use full control, and doesn't support Hindi."
                    : "Screenshots and questions go to Apple's Private Cloud Compute. It needs internet, has a usage limit and doesn't support Hindi.")
            }
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                permissionRow("Microphone", detail: "Hears you when you talk to Jarvis", symbol: "mic", granted: micGranted) {
                    Task {
                        if await !Permissions.requestMicrophone() {
                            Permissions.openSettings(for: "Privacy_Microphone")
                        }
                    }
                }
                Divider().overlay(Palette.line)
                permissionRow("Speech recognition", detail: "Turns what you say into text", symbol: "text.bubble", granted: speechGranted) {
                    Task {
                        if await !Permissions.requestSpeech() {
                            Permissions.openSettings(for: "Privacy_SpeechRecognition")
                        }
                    }
                }
                Divider().overlay(Palette.line)
                permissionRow("Screen recording", detail: "Sees your screen when you ask something", symbol: "rectangle.dashed", granted: screenGranted) {
                    Permissions.requestScreen()
                }
                Divider().overlay(Palette.line)
                permissionRow("Accessibility", detail: "Lets Jarvis click, type, and read your selected text and the app's buttons", symbol: "cursorarrow.click", granted: accessibilityGranted) {
                    Permissions.requestAccessibility()
                }
                Divider().overlay(Palette.line)
                permissionRow("Calendar", detail: "Reads and adds events when you ask. Optional", symbol: "calendar", granted: calendarGranted) {
                    Task {
                        if await !NativeServices.requestCalendar() { Permissions.openSettings(for: "Privacy_Calendars") }
                    }
                }
                Divider().overlay(Palette.line)
                permissionRow("Reminders", detail: "Reads and adds reminders when you ask. Optional", symbol: "checklist", granted: remindersGranted) {
                    Task {
                        if await !NativeServices.requestReminders() { Permissions.openSettings(for: "Privacy_Reminders") }
                    }
                }
                Divider().overlay(Palette.line)
                permissionRow("Contacts", detail: "Looks up someone's details when you ask. Optional", symbol: "person.crop.circle", granted: contactsGranted) {
                    Task {
                        if await !NativeServices.requestContacts() { Permissions.openSettings(for: "Privacy_Contacts") }
                    }
                }
            }
            Note(screenGranted
                ? "A screenshot of each display goes to your chosen AI only when you ask something."
                : "After you allow screen recording, quit and reopen Jarvis. A screenshot of each display goes to your chosen AI only when you ask something.")
        }
    }

    // MARK: - Parts

    private func howToStep(symbol: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 16))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 100, alignment: .topLeading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Palette.line))
    }

    private func permissionRow(_ title: String, detail: String, symbol: String, granted: Bool, request: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
            }
            Spacer()
            if granted {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                    Text("Allowed")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Palette.secondary)
            } else {
                Button(action: request) {
                    Text("Allow")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if Keychain.setGeminiKey(key) {
            keyDraft = ""
            hasKey = true
            testResult = "Key saved."
        } else {
            testResult = "Couldn't save the key to Keychain."
        }
    }

    private func previewVoice() {
        previewResult = settings.voiceEngine == .gemini && Keychain.geminiKey == nil
            ? "No Gemini key saved, so this is the Mac voice."
            : ""
        preview.voiceConfig = { [settings] in settings.voiceConfig() }
        preview.onVoiceError = { message in previewResult = message }
        preview.begin()
        preview.enqueue([.say(settings.hindiAssistant
            ? "नमस्ते, मैं जार्विस हूँ। शॉर्टकट दबाकर रखिए और अपनी स्क्रीन के बारे में कुछ भी पूछिए।"
            : "Hi, I'm Jarvis. Hold the shortcut and ask me about anything on your screen.")])
        preview.finishInput()
    }

    private func qualityName(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Standard"
        }
    }

    private func test() {
        isTesting = true
        testResult = ""
        Task {
            defer { isTesting = false }
            do {
                let provider = try settings.makeProvider()
                let request = AIRequest(system: "Reply with one short friendly sentence.", userText: "Say that the connection works.")
                var reply = ""
                for try await chunk in provider.stream(request) { reply += chunk }
                testResult = reply.isEmpty ? "No reply came back." : reply
            } catch {
                testResult = error.localizedDescription
            }
        }
    }
}

private struct MemoryPage: View {
    @ObservedObject var memory: MemoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if memory.facts.isEmpty {
                Card {
                    Row("Nothing saved yet", detail: "Say something like \"remember that my main project is Jarvis\"") { EmptyView() }
                }
            } else {
                Card {
                    ForEach(Array(memory.facts.enumerated()), id: \.element) { index, fact in
                        if index > 0 { Divider().overlay(Palette.line) }
                        Row(fact) {
                            OutlineButton("Delete") { memory.remove(fact) }
                        }
                    }
                }
                OutlineButton("Forget everything") { memory.clear() }
            }
            Note("Saved only on this Mac, and sent to your chosen AI with each request. Jarvis saves a fact when you ask it to remember something or state a lasting preference.")
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Palette.line))
    }
}

struct Row<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 50)
        .padding(.vertical, 3)
    }
}

/// A switch in the app's black and white: a white track with a black knob when on.
struct MonoSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? Color.white : Color.white.opacity(0.14))
                .frame(width: 38, height: 22)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? Color.black : Color.white.opacity(0.75))
                        .frame(width: 18, height: 18)
                        .padding(2)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

struct DarkField: View {
    @Binding var text: String
    let width: CGFloat
    var isSecure = false
    var placeholder = ""

    var body: some View {
        Group {
            if isSecure {
                SecureField("", text: $text, prompt: prompt)
            } else {
                TextField("", text: $text, prompt: prompt)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(width: width, height: 28)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Palette.line))
    }

    private var prompt: Text {
        Text(placeholder).foregroundStyle(.white.opacity(0.4))
    }
}

struct OutlineButton: View {
    let title: String
    var symbol: String?
    var isEnabled = true
    let action: () -> Void

    init(_ title: String, symbol: String? = nil, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}
