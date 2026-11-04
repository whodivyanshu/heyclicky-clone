import AppKit
import Combine
import JarvisCore

/// Runs a turn (hold to talk or type, then capture, ask, speak and point)
/// and any click-by-click walkthrough that follows from it.
@MainActor
final class Coordinator {
    let settings: AppSettings
    let overlay = OverlayController()
    let island = IslandModel()
    var onModeChange: (CompanionMode) -> Void = { _ in }
    var openSettings: () -> Void = {}

    let hotkeys = HotkeyMonitor()
    let speechIn = SpeechInput()
    let speechOut = SpeechOutput()
    var mode = CompanionMode.idle
    var pressedAt: Date?
    var isListening = false
    var turn: Task<Void, Never>?
    var screens: [ScreenMap] = []
    var history: [ChatTurn] = [] {
        didSet { saveLatestTurn() }
    }
    var didPoint = false
    var allowsActions = false
    var sawAction = false
    /// Once something has run this turn the screenshot may be out of date, so a click could land on the wrong thing.
    var didRunAction = false
    var actionFailure: String?
    var isTurnRecorded = false
    var returnTask: Task<Void, Never>?

    /// Set while a request is running with full control turned on.
    var control: ControlSession?
    var wantsNextStep = false
    /// An app or page that was just opened may not be ready, so keys sent now could land in the wrong window.
    var didOpenSomething = false
    /// The reply was planned for a screen that turned out to be different, so the rest of it is dropped and Jarvis looks again.
    var abandonedReply = false
    var sawDone = false
    var sawTarget = false
    var ranScreenAction = false
    var ranClickOrKeys = false
    var sawPoint = false
    var madePlan = false
    /// How the screen looked before opening something, to tell when the new window has appeared.
    var beforeOpening: [UInt8]?
    /// A screenshot started when the shortcut was released, so it's ready by the time the transcript is.
    var pendingLook: Task<Look, Error>?
    var clock = TurnClock()
    /// While a job runs, words wait for the end of the reply, and are only spoken if the job is finished.
    var heldBeats: [Beat] = []
    /// What Jarvis itself typed for this request. Shown when it asks, since this is what would actually be sent.
    var lastTyped: String?
    /// Only their own new words can change what's remembered, not later steps that follow a screenshot.
    var isDirectRequest = false
    var controls: [ScreenControl] = []
    /// Set for a turn on Apple's on-device model, which can't be trusted with everything it asks for.
    var onDeviceGuard: OnDeviceGuard?

    /// What the model said the next step will do, which also makes that step need a yes.
    var declaredConfirmation: String?
    var pendingConfirmation: CheckedContinuation<Bool, Never>?
    var confirmationTimeout: Task<Void, Never>?
    var isAnsweringConfirmation = false

    /// Data from Calendar, Reminders or Contacts, waiting to go back to the model.
    var lookupResults: [String] = []
    var lookupRounds = 0
    /// This round is answering from looked-up data, so without full control it can only use the direct abilities.
    var answeringLookup = false
    /// A scheduled routine may be running with nobody at the Mac.
    var unattended = false
    /// What they asked for, including while the steps of it run.
    var requestText = ""
    /// Ties every step of a job to one saved conversation entry.
    var conversationID = UUID()
    /// The screenshot the current step decided from, kept if they chose to.
    var latestScreenshot: Data?

    let wakeWord = WakeWordListener()
    let bargeIn = BargeInListener()
    var isBargeCapturing = false
    var isDictating = false
    let meetingRecorder = MeetingRecorder()
    var currentMeeting: MeetingNote?
    var meetingLimit: Task<Void, Never>?
    var onMeetingChange: (Bool) -> Void = { _ in }
    var shortcutReply: CheckedContinuation<String, Never>?
    var wakeWordUpdate: Task<Void, Never>?
    var isWakeCapturing = false
    var isFollowingUp = false
    var followUpHeardAt: Date?
    var lastTurnWasVoice = false
    var isWatching = false
    var lastWatched: [UInt8]?
    var watchRules = ScreenWatchRules()
    var subscriptions = Set<AnyCancellable>()

    var guide: GuideSession?
    var clickMonitor: Any?
    var guideTimeout: Task<Void, Never>?

    static let minimumHold: TimeInterval = 0.25
    static let historyLimit = 6
    static let maxLookupRounds = 3
    /// Silent steps have no words, and an empty turn in the history can be rejected by the provider.
    static let workingPlaceholder = "Working on it."
    static let pointHoldAfterSpeech: UInt64 = 2_500_000_000
    /// How long a finished reply stays readable on the island.
    static let replyLinger: Double = 5
    /// Gives the app time to react to a click before the next screenshot, or less once the screen has stopped changing.
    /// The minimum leaves time for a list to filter or a menu to appear, since a stale screen could mean a wrong click.
    static let settleAfterClick = (minimum: 0.35, limit: 0.7)
    /// Apps and pages take longer to be ready than a click takes to register.
    static let settleAfterOpening = (minimum: 0.3, limit: 1.5)
    static let guideWait: UInt64 = 120_000_000_000
    static let confirmationWait: UInt64 = 60_000_000_000

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        overlay.showWhenIdle = { [settings] in settings.showWhenIdle }
        overlay.start()

        hotkeys.hotkey = { [settings] in settings.hotkey }
        hotkeys.onPress = { [weak self] in self?.pressed() }
        hotkeys.onRelease = { [weak self] in self?.released() }
        hotkeys.onEscape = { [weak self] in self?.escape() }
        hotkeys.start()

        speechIn.onLevel = { [weak self] level in
            self?.overlay.setLevel(level)
            self?.island.level = CGFloat(level)
        }
        speechIn.onPartial = { [weak self] text in
            guard let self, self.isListening else { return }
            self.island.transcript = text
            if self.isFollowingUp { self.followUpHeardAt = Date() }
        }

        speechOut.voiceConfig = { [settings] in settings.voiceConfig() }
        speechOut.onPoint = { [weak self] in self?.point(at: $0) }
        speechOut.onTarget = { [weak self] in self?.target($0) }
        speechOut.onAction = { [weak self] in await self?.act($0) }
        speechOut.onClick = { [weak self] in await self?.click($0) }
        speechOut.onDrained = { [weak self] in self?.speechFinished() }
        speechOut.onVoiceError = { [weak self] in self?.island.notice = $0 }

        island.onAsk = { [weak self] in self?.ask($0) }
        island.onStop = { [weak self] in self?.escape() }
        island.onConfirm = { [weak self] in self?.resolveConfirmation($0) }
        island.onOpenSettings = { [weak self] in
            self?.island.isOpen = false
            self?.openSettings()
        }

        ActionRunner.appPolicy = { [settings] in settings.appPolicy }
        NotificationCenter.default.addObserver(forName: .retryMeetingSummary, object: nil, queue: .main) { [weak self] notification in
            let id = notification.userInfo?["id"] as? UUID
            MainActor.assumeIsolated {
                guard let self, let note = self.settings.meetings.book.notes.first(where: { $0.id == id }) else { return }
                Task { await self.summarize(note) }
            }
        }
        startAutomation()
        startVoiceFeatures()
    }

    /// Saves the conversation as it stands. The reply can still change until the job ends.
    private func saveLatestTurn() {
        guard settings.saveConversations, let last = history.last else { return }
        settings.conversations.save(ConversationEntry(id: conversationID, date: Date(), user: last.user, assistant: last.assistant))
    }

    /// Dev check from `--demo`: plays through every island state and the pointer's flight, without any permissions.
    func runDemo() {
        guard let screen = NSScreen.main else { return }
        Task {
            func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            island.transcript = ""
            island.show(.listening)
            for word in ["How", "How do I", "How do I export", "How do I export this as a PDF?"] {
                island.level = 0.7
                island.transcript = word
                await wait(0.7)
            }
            island.level = 0
            island.show(.thinking)
            await wait(1.5)
            island.reply = "Open the File menu first, then look for Export."
            island.show(.speaking)
            setMode(.speaking)
            overlay.fly(to: CGPoint(x: screen.frame.midX, y: screen.frame.midY), label: "File menu", ringRadius: 40)
            await wait(3)
            island.guideStep = 1
            island.show(.guiding)
            setMode(.idle)
            await wait(3)
            island.confirmTitle = "Press Return in WhatsApp"
            island.confirmDetail = "Send \"How are you?\" to Lovesh\nTyped: How are you?"
            island.show(.confirming)
            await wait(4)
            overlay.returnToCursor()
            island.rest()
        }
    }

    func setMode(_ mode: CompanionMode) {
        self.mode = mode
        overlay.setMode(mode)
        onModeChange(mode)
        updateWakeWord()
        updateBargeIn()
    }


    func show(_ error: Error) {
        NSSound(named: "Basso")?.play()
        endGuide()
        overlay.returnToCursor()
        island.showMessage(error.localizedDescription)
        finishShortcut(with: error.localizedDescription)
        setMode(.idle)
    }
}
