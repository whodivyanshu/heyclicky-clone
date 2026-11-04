import AppKit
import JarvisCore
import ServiceManagement
import SwiftUI

// The pages for what Jarvis does without the shortcut, and for what it keeps and may touch.

/// "Hey Jarvis", follow-ups and offers of help.
struct HandsFreePage: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Row("Dictate anywhere", detail: "Hold this, speak, and let go. Your words appear wherever you're typing") {
                    Picker("", selection: $settings.dictationHotkey) {
                        ForEach(DictationHotkey.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider().overlay(Palette.line)
                Row("Dictation language", detail: "Hindi needs its speech recognizer, and works for Hindi mixed with English") {
                    Picker("", selection: $settings.dictationLanguage) {
                        ForEach(DictationLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider().overlay(Palette.line)
                Row("Clean up dictation with AI", detail: "Fixes punctuation and false starts, but sends what you said to your AI and is a little slower. Removing \"um\" and \"uh\" is always free") {
                    Toggle("", isOn: $settings.dictationCleanup).labelsHidden().toggleStyle(MonoSwitch())
                }
            }
            Card {
                Row("Talk over Jarvis to interrupt", detail: "Speak while Jarvis is talking and it stops and listens. Say \"stop\" to just stop it. Works best with headphones") {
                    Toggle("", isOn: $settings.bargeInEnabled).labelsHidden().toggleStyle(MonoSwitch())
                }
                Divider().overlay(Palette.line)
                Row("Listen for \"Hey Jarvis\"", detail: "Say it, then your request. The microphone stays on while Jarvis is idle, and macOS shows its orange dot") {
                    Toggle("", isOn: $settings.wakeWordEnabled).labelsHidden().toggleStyle(MonoSwitch())
                }
                Divider().overlay(Palette.line)
                Row("Keep listening after a reply", detail: "Listens for 6 seconds after a spoken reply, so you can carry on without the shortcut") {
                    Toggle("", isOn: $settings.followUpEnabled).labelsHidden().toggleStyle(MonoSwitch())
                }
                Divider().overlay(Palette.line)
                Row("Offer help with problems on screen", detail: "Looks for messages like \"Build failed\" and offers to help, at most once every 5 minutes") {
                    Toggle("", isOn: $settings.screenWatchEnabled).labelsHidden().toggleStyle(MonoSwitch())
                }
            }
            Note("\"Hey Jarvis\" is recognized on this Mac, and no audio leaves it until a request is sent to your AI. Listening all the time uses more battery. Offers read your screen on this Mac every 20 seconds, and nothing is sent to your AI unless you choose \"Take a look\".")
        }
    }
}

struct RoutinesPage: View {
    @ObservedObject var routines: RoutineStore
    @State private var name = ""
    @State private var when = ""
    @State private var request = ""
    @State private var problem = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !routines.book.routines.isEmpty {
                Card {
                    ForEach(Array(routines.book.routines.enumerated()), id: \.element.id) { index, routine in
                        if index > 0 { Divider().overlay(Palette.line) }
                        Row(routine.name, detail: "\(routine.trigger.summary): \(routine.request)") {
                            OutlineButton("Delete") { routines.remove(id: routine.id) }
                        }
                    }
                }
            }
            Card {
                Row("Name") { DarkField(text: $name, width: 300, placeholder: "Focus") }
                Divider().overlay(Palette.line)
                Row("When") { DarkField(text: $when, width: 300, placeholder: "say focus mode, or weekdays 09:00") }
                Divider().overlay(Palette.line)
                Row("What to do") { DarkField(text: $request, width: 300, placeholder: "Quit Slack and open Notes") }
                Divider().overlay(Palette.line)
                Row("Add routine", detail: problem.isEmpty ? nil : problem) {
                    OutlineButton("Add", isEnabled: !name.isEmpty && !when.isEmpty && !request.isEmpty, action: add)
                }
            }
            Note("You can also say \"every morning at 9, open my work apps and read my calendar\". A routine you start by saying its phrase works like any request. A scheduled one never sees your screen, clicks or types, in case you're away. It runs within 5 minutes of its time if the Mac is awake and unlocked, and is skipped otherwise.")
        }
    }

    private func add() {
        guard let trigger = RoutineTrigger.parse(when) else {
            problem = "Try \"say focus mode\", \"daily 09:00\", \"weekdays 18:30\" or \"mon,thu 08:00\"."
            return
        }
        guard routines.add(Routine(name: name, trigger: trigger, request: request)) else {
            problem = "You've reached the limit of \(RoutineBook.maxRoutines) routines."
            return
        }
        name = ""
        when = ""
        request = ""
        problem = ""
    }
}

struct HistoryPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var conversations: ConversationStore
    @State private var query = ""

    private var results: [ConversationEntry] {
        Array(conversations.book.search(query).prefix(100))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Row("Save my conversations", detail: "What you said and what Jarvis replied. Screenshots and selected text aren't saved") {
                    Toggle("", isOn: $settings.saveConversations).labelsHidden().toggleStyle(MonoSwitch())
                }
            }
            HStack(spacing: 8) {
                DarkField(text: $query, width: 300, placeholder: "Search your conversations")
                Spacer()
                if !conversations.book.entries.isEmpty {
                    OutlineButton("Delete all") { conversations.clear() }
                }
            }
            if results.isEmpty {
                Note(conversations.book.entries.isEmpty ? "Nothing saved yet." : "Nothing matches that.")
            } else {
                Card {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().overlay(Palette.line) }
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.user)
                                    .font(.system(size: 13, weight: .medium))
                                Text(entry.assistant)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.secondary)
                                    .textSelection(.enabled)
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            OutlineButton("Delete") { conversations.remove(id: entry.id) }
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                    }
                }
            }
            Note("Saved only on this Mac, in a file only your user can read, and limited to the latest \(ConversationBook.maxEntries). Past conversations aren't sent to your AI after you quit.")
        }
    }
}

struct ActivityPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var activity: ActivityStore

    private var recent: [ActivityEntry] {
        Array(activity.book.entries.reversed().prefix(100))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Row("Keep a record of what Jarvis does", detail: "Every click, key, app and action, and whether it worked. It can include what Jarvis typed") {
                    Toggle("", isOn: $settings.keepActivityLog).labelsHidden().toggleStyle(MonoSwitch())
                }
                Divider().overlay(Palette.line)
                Row("Keep a screenshot for each step", detail: "Shows what Jarvis was looking at, including anything private on your screen") {
                    Toggle("", isOn: $settings.keepActivityScreenshots).labelsHidden().toggleStyle(MonoSwitch())
                }
            }
            if recent.isEmpty {
                Note("Nothing recorded yet.")
            } else {
                OutlineButton("Delete all") { activity.clear() }
                Card {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().overlay(Palette.line) }
                        HStack(spacing: 12) {
                            Image(systemName: entry.failure == nil ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(entry.failure == nil ? Palette.secondary : JarvisStyle.amber)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.summary)
                                    .font(.system(size: 13, weight: .medium))
                                Text([entry.failure, "For: \(entry.request)", entry.date.formatted(date: .abbreviated, time: .standard)].compactMap { $0 }.joined(separator: "\n"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if let url = activity.screenshotURL(for: entry) {
                                OutlineButton("Screenshot") { NSWorkspace.shared.open(url) }
                            }
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                    }
                }
            }
            Note("Saved only on this Mac, in files only your user can read, and limited to the latest \(ActivityBook.maxEntries) steps.")
        }
    }
}

/// Which apps Jarvis may use the mouse and keyboard in.
struct SafetyPage: View {
    @ObservedObject var settings: AppSettings
    @State private var running: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Row("Only use the apps I list", detail: "Jarvis won't click or type anywhere else") {
                    Toggle("", isOn: $settings.appPolicy.onlyAllowed).labelsHidden().toggleStyle(MonoSwitch())
                }
            }
            if settings.appPolicy.onlyAllowed {
                appList("Apps Jarvis can use", apps: $settings.appPolicy.allowed)
            }
            appList("Apps Jarvis must never use", apps: $settings.appPolicy.blocked)
            Note("These lists cover clicking and typing. Jarvis can still open and quit these apps when you ask. Offers of help also skip apps you've blocked. Built-in protections for terminals, password fields, System Settings and security dialogs always apply.")
        }
        .onAppear {
            running = ActionRunner.runningApps().compactMap(\.localizedName).sorted()
        }
    }

    private func appList(_ title: String, apps: Binding<[String]>) -> some View {
        Card {
            Row(title) {
                Picker("", selection: Binding<String>(
                    get: { "" },
                    set: { app in
                        if !app.isEmpty, !apps.wrappedValue.contains(app) { apps.wrappedValue.append(app) }
                    }
                )) {
                    Text("Add a running app").tag("")
                    ForEach(running.filter { !apps.wrappedValue.contains($0) }, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            ForEach(apps.wrappedValue, id: \.self) { app in
                Divider().overlay(Palette.line)
                Row(app) {
                    OutlineButton("Remove") { apps.wrappedValue.removeAll { $0 == app } }
                }
            }
        }
    }
}

/// Opening Jarvis at login. macOS keeps this setting, so it's read back from the system rather than stored here.
struct LaunchAtLoginRow: View {
    @State private var isOn = SMAppService.mainApp.status == .enabled
    @State private var problem: String?

    var body: some View {
        Row("Open Jarvis when you log in", detail: problem) {
            Toggle("", isOn: Binding(get: { isOn }, set: change)).labelsHidden().toggleStyle(MonoSwitch())
        }
    }

    private func change(_ wanted: Bool) {
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            problem = SMAppService.mainApp.status == .requiresApproval ? "Allow Jarvis in System Settings, under Login Items." : nil
        } catch {
            problem = "macOS wouldn't change this. Move Jarvis to Applications and try again."
        }
        isOn = SMAppService.mainApp.status == .enabled
    }
}

/// The Ollama model picker, which lists what's installed on this Mac.
struct OllamaRow: View {
    @ObservedObject var settings: AppSettings
    @State private var models: [String]?
    @State private var checked = false

    var body: some View {
        Group {
            if let models, !models.isEmpty {
                Row("Model", detail: "Pick a model that can read images, or Jarvis won't be able to see your screen") {
                    Picker("", selection: $settings.ollamaModel) {
                        Text("Choose a model").tag("")
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } else {
                Row("Model", detail: !checked ? "Checking…" : models == nil ? "Ollama isn't running. Start it, then check again." : "No models installed yet. Run: ollama pull llama3.2-vision") {
                    OutlineButton("Check again", action: load)
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        Task {
            models = await OllamaProvider.installedModels()
            checked = true
        }
    }
}

struct MeetingsPage: View {
    @ObservedObject var meetings: MeetingStore
    @ObservedObject var settings: AppSettings
    @State private var opened: UUID?
    @State private var added: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if meetings.book.notes.isEmpty {
                Card {
                    Row("No meeting notes yet", detail: "Say \"start meeting notes\" or use the menu bar icon") { EmptyView() }
                }
            } else {
                Card {
                    ForEach(Array(meetings.book.notes.reversed().enumerated()), id: \.element.id) { index, note in
                        if index > 0 { Divider().overlay(Palette.line) }
                        row(note)
                    }
                }
            }
            Note("A red dot on the island shows when Jarvis is taking notes. It hears your microphone and your Mac's sound, and turns them into text on this Mac without keeping any audio. Tell people on the call before you start, because some places require their consent. The transcript goes to your chosen AI for the summary, and notes stop by themselves after 3 hours.")
        }
    }

    private func row(_ note: MeetingNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(note.start.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                OutlineButton(opened == note.id ? "Hide" : "Open") { opened = opened == note.id ? nil : note.id }
                OutlineButton("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString([note.summary, note.transcript].compactMap { $0 }.joined(separator: "\n\n"), forType: .string)
                }
                OutlineButton("Delete") { meetings.remove(id: note.id) }
            }
            if let problem = note.problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(JarvisStyle.amber)
                OutlineButton("Try again") { retry(note) }
            }
            if opened == note.id {
                if let summary = note.summary {
                    Text(summary).font(.system(size: 12)).textSelection(.enabled)
                    let items = MeetingRules.actionItems(in: summary)
                    if !items.isEmpty {
                        OutlineButton(added == note.id ? "Added to Reminders" : "Add \(items.count) action items to Reminders", isEnabled: added != note.id) { addReminders(items, for: note) }
                    }
                }
                Text(note.transcript)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
    }

    private func addReminders(_ items: [String], for note: MeetingNote) {
        Task {
            for item in items {
                // A bar would be read as the due date.
                let title = item.replacingOccurrences(of: "|", with: " ")
                _ = await NativeServices.run(ActionTag(kind: .addReminder, value: title))
            }
            added = note.id
        }
    }

    private func retry(_ note: MeetingNote) {
        NotificationCenter.default.post(name: .retryMeetingSummary, object: nil, userInfo: ["id": note.id])
    }
}

extension Notification.Name {
    static let retryMeetingSummary = Notification.Name("local.jarvis.retryMeetingSummary")
}

struct TeachingPage: View {
    @ObservedObject var settings: AppSettings
    @State private var custom: [TeachingPack] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Row("Use teaching notes", detail: "When you ask to learn something, Jarvis adds notes for the app in front of you") {
                    Toggle("", isOn: $settings.teachingEnabled).labelsHidden().toggleStyle(MonoSwitch())
                }
            }
            Card {
                ForEach(Array((custom + TeachingPack.builtIn).enumerated()), id: \.element.id) { index, pack in
                    if index > 0 { Divider().overlay(Palette.line) }
                    Row(pack.name, detail: (pack.isBuiltIn ? "Built in, for " : "Yours, for ") + pack.apps.joined(separator: ", ")) { EmptyView() }
                }
            }
            OutlineButton("Open my teaching packs folder") {
                try? FileManager.default.createDirectory(at: TeachingFiles.folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(TeachingFiles.folder)
            }
            Note("Add your own by saving a .md file in that folder. Its first line names the apps, such as \"apps: Figma, FigJam\", and the rest is your notes in plain words. Yours come before a built-in pack for the same app.")
        }
        .onAppear { custom = TeachingFiles.custom() }
    }
}

struct ScreenMemoryPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var memory: ScreenMemoryStore
    @State private var query = ""
    @State private var results: [ScreenMemoryHit] = []
    @State private var searched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Row("Remember text from my screen", detail: "Reads your screen every 20 seconds, so you can ask \"where did I see that error yesterday?\"") {
                    Toggle("", isOn: $settings.screenMemoryEnabled).labelsHidden().toggleStyle(MonoSwitch())
                }
                Divider().overlay(Palette.line)
                Row("Keep it for") {
                    Picker("", selection: $settings.screenMemoryDays) {
                        Text("1 day").tag(1)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider().overlay(Palette.line)
                Row("Saved", detail: "\(memory.count) screens") {
                    OutlineButton("Delete everything", isEnabled: memory.count > 0) {
                        memory.clear()
                        results = []
                    }
                }
            }
            HStack(spacing: 8) {
                DarkField(text: $query, width: 300, placeholder: "Search what was on your screen")
                OutlineButton("Search", isEnabled: !query.isEmpty) {
                    results = memory.search(query)
                    searched = true
                }
            }
            if !results.isEmpty {
                Card {
                    ForEach(Array(results.enumerated()), id: \.offset) { index, hit in
                        if index > 0 { Divider().overlay(Palette.line) }
                        Row(hit.snippet, detail: "\(hit.app), \(hit.date.formatted(date: .abbreviated, time: .shortened))") { EmptyView() }
                    }
                }
            } else if searched {
                Note("Nothing matches that.")
            }
            Note("Only text is kept, never images, on this Mac in a file only your user can read. It can still hold private things you had on screen. Jarvis skips password fields, password managers, private browser windows, a locked screen and apps you've blocked, and hides what looks like card numbers, keys and passwords, but it can miss some. When you ask about something you saw, the matching text goes to your chosen AI.")
        }
        .onAppear { memory.refreshCount() }
    }
}

/// Installing Kokoro and choosing its voices. Nothing is downloaded until they ask.
struct KokoroRows: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var installer: KokoroInstaller

    private var total: Int { KokoroCatalog.runtime.megabytes + KokoroCatalog.model.megabytes }

    var body: some View {
        Group {
            if installer.isInstalled {
                Row("English voice") {
                    Picker("", selection: $settings.kokoroEnglishVoice) {
                        ForEach(KokoroCatalog.englishVoices) { Text("\($0.name) (\($0.description))").tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider().overlay(Palette.line)
                Row("Hindi voice", detail: "Used for any reply written in Hindi") {
                    Picker("", selection: $settings.kokoroHindiVoice) {
                        ForEach(KokoroCatalog.hindiVoices) { Text("\($0.name) (\($0.description))").tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider().overlay(Palette.line)
                Row("Installed on this Mac", detail: "Takes about 220 MB") {
                    OutlineButton("Remove") { installer.remove() }
                }
            } else if !KokoroInstaller.isSupportedMac {
                Row("Kokoro needs a Mac with Apple silicon") { EmptyView() }
            } else {
                switch installer.state {
                case .working(let step):
                    Row("Installing Kokoro", detail: step) { ProgressView().controlSize(.small) }
                case .idle:
                    Row("Install Kokoro", detail: "Downloads about \(total) MB from the sherpa-onnx project on GitHub, and checks each file before installing it") {
                        OutlineButton("Download", action: installer.install)
                    }
                case .failed(let problem):
                    Row("Install Kokoro", detail: problem) {
                        OutlineButton("Try again", action: installer.install)
                    }
                }
            }
        }
    }
}
