import AppKit
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

    private let hotkeys = HotkeyMonitor()
    private let speechIn = SpeechInput()
    private let speechOut = SpeechOutput()
    private var mode = CompanionMode.idle
    private var pressedAt: Date?
    private var isListening = false
    private var turn: Task<Void, Never>?
    private var screens: [ScreenMap] = []
    private var history: [ChatTurn] = []
    private var didPoint = false
    private var allowsActions = false
    private var sawAction = false
    private var actionFailure: String?
    private var isTurnRecorded = false
    private var returnTask: Task<Void, Never>?

    private var guide: GuideSession?
    private var clickMonitor: Any?
    private var guideTimeout: Task<Void, Never>?

    private static let minimumHold: TimeInterval = 0.25
    private static let historyLimit = 6
    private static let pointHoldAfterSpeech: UInt64 = 2_500_000_000
    /// How long a finished reply stays readable on the island.
    private static let replyLinger: Double = 5
    /// Gives the app time to react to a click before the next screenshot.
    private static let settleAfterClick: UInt64 = 700_000_000
    private static let guideWait: UInt64 = 120_000_000_000

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
        }

        speechOut.voiceConfig = { [settings] in settings.voiceConfig() }
        speechOut.onPoint = { [weak self] in self?.point(at: $0) }
        speechOut.onTarget = { [weak self] in self?.target($0) }
        speechOut.onAction = { [weak self] in await self?.act($0) }
        speechOut.onDrained = { [weak self] in self?.speechFinished() }
        speechOut.onVoiceError = { [weak self] in self?.island.notice = $0 }

        island.onAsk = { [weak self] in self?.ask($0) }
        island.onStop = { [weak self] in self?.escape() }
        island.onOpenSettings = { [weak self] in
            self?.island.isOpen = false
            self?.openSettings()
        }
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
            overlay.returnToCursor()
            island.rest()
        }
    }

    private func setMode(_ mode: CompanionMode) {
        self.mode = mode
        overlay.setMode(mode)
        onModeChange(mode)
    }

    // MARK: - Input

    private func pressed() {
        interrupt()
        island.isOpen = false
        pressedAt = Date()
        isListening = true
        setMode(.listening)
        island.rest()
        island.show(.listening)

        Task {
            guard await ensureVoicePermissions() else {
                isListening = false
                return
            }
            // The key may have been released during a permission prompt.
            guard isListening else { return }
            do {
                try speechIn.start()
            } catch {
                isListening = false
                show(error)
            }
        }
    }

    private func released() {
        guard isListening else { return }
        isListening = false
        overlay.setLevel(0)
        island.level = 0

        if let pressedAt, Date().timeIntervalSince(pressedAt) < Self.minimumHold {
            // Probably part of another keyboard shortcut.
            speechIn.cancel()
            island.rest()
            setMode(.idle)
            return
        }
        turn = Task { await runVoiceTurn() }
    }

    /// A typed question or a suggestion from the island's panel.
    private func ask(_ text: String) {
        interrupt()
        island.isOpen = false
        island.rest()
        guide = GuideSession(task: text)
        turn = Task { await perform(transcript: text) }
    }

    private func escape() {
        guard mode != .idle || guide != nil || island.phase != .resting else { return }
        isListening = false
        interrupt()
        overlay.setCaption(nil)
        overlay.setLevel(0)
        island.rest()
        setMode(.idle)
    }

    private func interrupt() {
        turn?.cancel()
        turn = nil
        returnTask?.cancel()
        returnTask = nil
        endGuide()
        speechIn.cancel()
        speechOut.stop()
        overlay.returnToCursor()
        didPoint = false
    }

    private func ensureVoicePermissions() async -> Bool {
        if !Permissions.microphone, await !Permissions.requestMicrophone() {
            show(JarvisMessage("Jarvis needs microphone access. Allow it in Settings."))
            openSettings()
            return false
        }
        if !Permissions.speech, await !Permissions.requestSpeech() {
            show(JarvisMessage("Jarvis needs speech recognition access. Allow it in Settings."))
            openSettings()
            return false
        }
        return true
    }

    // MARK: - Turn

    private func runVoiceTurn() async {
        do {
            let transcript = try await speechIn.stop()
            try Task.checkCancellation()
            guard !transcript.isEmpty else {
                island.showMessage("Didn't catch that.", lasting: 2)
                setMode(.idle)
                return
            }
            guide = GuideSession(task: transcript)
            await perform(transcript: transcript)
        } catch is CancellationError {
            // Interrupted: whatever interrupted the turn has already reset the state.
        } catch {
            if !Task.isCancelled { show(error) }
        }
    }

    private func perform(transcript: String) async {
        do {
            try await exchange(transcript: transcript, guidance: nil, historyEntry: transcript)
        } catch is CancellationError {
            // Interrupted: whatever interrupted the turn has already reset the state.
        } catch {
            if !Task.isCancelled { show(error) }
        }
    }

    /// One round with the AI: takes fresh screenshots, streams the reply, and hands it to speech.
    private func exchange(transcript: String, guidance: String?, historyEntry: String) async throws {
        setMode(.thinking)
        island.reply = ""
        island.notice = ""
        island.activity = ""
        island.show(.thinking)
        // Walkthrough follow-ups have no new words from the user, so only a direct request can act.
        allowsActions = guidance == nil
        sawAction = false
        actionFailure = nil
        isTurnRecorded = false

        let provider = try settings.makeProvider()
        let captured = try await capture()
        try Task.checkCancellation()
        screens = captured.map(\.map)

        let request = AIRequest(
            system: Prompt.system,
            history: history,
            userText: userMessage(transcript: transcript, guidance: guidance, captured: captured),
            jpegImages: captured.map(\.jpeg)
        )

        var parser = ResponseParser()
        var reply = ""
        speechOut.begin()
        for try await chunk in provider.stream(request) {
            try Task.checkCancellation()
            reply += chunk
            deliver(parser.feed(chunk))
        }
        try Task.checkCancellation()
        deliver(parser.finish())

        let spoken = ResponseParser.spokenText(of: reply)
        if spoken.isEmpty, !didPoint, !sawAction {
            throw JarvisMessage("The model sent back an empty reply.")
        }
        history.append(ChatTurn(user: historyEntry, assistant: actionFailure ?? spoken))
        history = Array(history.suffix(Self.historyLimit))
        island.conversation = history
        isTurnRecorded = true
        speechOut.finishInput()
    }

    private func capture() async throws -> [CapturedScreen] {
        guard Permissions.screen else {
            Permissions.requestScreen()
            throw JarvisMessage("Jarvis needs Screen Recording access. Allow it in System Settings, then reopen Jarvis.")
        }
        return try await ScreenCapture.captureAll()
    }

    private func userMessage(transcript: String, guidance: String?, captured: [CapturedScreen]) -> String {
        let mouse = NSEvent.mouseLocation
        let cursor = captured.first { $0.map.frame.contains(mouse) }.map { screen -> (screen: Int, x: Int, y: Int) in
            let point = screen.map.imagePoint(global: mouse)
            return (screen.map.index, Int(point.x), Int(point.y))
        }
        return Prompt.userMessage(
            transcript: transcript,
            guidance: guidance,
            screens: captured.map {
                Prompt.ScreenInfo(index: $0.map.index, pixelWidth: Int($0.map.imageSize.width), pixelHeight: Int($0.map.imageSize.height))
            },
            cursor: cursor,
            frontmostApp: NSWorkspace.shared.frontmostApplication?.localizedName
        )
    }

    private func deliver(_ beats: [Beat]) {
        guard !beats.isEmpty else { return }
        if mode != .speaking { setMode(.speaking) }
        for beat in beats {
            switch beat {
            case .say(let text):
                guard actionFailure == nil else { continue }
                island.reply += island.reply.isEmpty ? text : " " + text
            case .action:
                sawAction = true
            case .point, .target:
                break
            }
        }
        if island.phase == .thinking { island.show(.speaking) }
        speechOut.enqueue(beats)
    }

    /// Returns what to say instead of the model's reply if the action failed.
    private func act(_ tag: ActionTag) async -> String? {
        guard allowsActions else { return nil }
        island.activity = ActionRunner.progress(for: tag)
        let result = await ActionRunner.run(tag)
        // A failure is explained in the reply itself, so only success gets the checkmark line.
        island.activity = result.failure == nil ? result.summary : ""
        guard let failure = result.failure else { return nil }
        actionFailure = failure
        island.reply = failure
        // The reply may already be in the history, and it shouldn't claim something happened that didn't.
        if isTurnRecorded, let last = history.last {
            history[history.count - 1] = ChatTurn(user: last.user, assistant: failure)
            island.conversation = history
        }
        return failure
    }

    private func point(at tag: PointTag) {
        guard let screen = screen(for: tag) else { return }
        didPoint = true
        overlay.fly(to: screen.globalPoint(imageX: tag.x, imageY: tag.y), label: tag.label)
    }

    private func screen(for tag: PointTag) -> ScreenMap? {
        let index = tag.screen ?? 1
        return screens.first { $0.index == index }
    }

    private func speechFinished() {
        setMode(.idle)
        if guide?.current != nil { return }
        guide = nil
        island.rest(after: Self.replyLinger)
        guard didPoint else { return }
        didPoint = false
        // Leave the pointer on the target long enough to act on it.
        returnTask = Task {
            try? await Task.sleep(nanoseconds: Self.pointHoldAfterSpeech)
            guard !Task.isCancelled else { return }
            overlay.returnToCursor()
        }
    }

    // MARK: - Guided walkthrough

    private func target(_ tag: PointTag) {
        guard let screen = screen(for: tag), guide?.setTarget(tag) == true else {
            // No guide to attach to, or out of steps: still show the location.
            point(at: tag)
            return
        }
        didPoint = true
        let pointsPerPixel = screen.frame.width / screen.imageSize.width
        overlay.fly(
            to: screen.globalPoint(imageX: tag.x, imageY: tag.y),
            label: tag.label,
            ringRadius: CGFloat(tag.radius ?? 0) * pointsPerPixel
        )
        island.guideStep = (guide?.completed.count ?? 0) + 1
        island.show(.guiding)
        watchForClick()
    }

    /// Clicks go through to the app as usual. Jarvis only notices where they landed.
    private func watchForClick() {
        stopWatchingForClick()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.clicked(at: NSEvent.mouseLocation) }
            }
        }
        guideTimeout = Task {
            try? await Task.sleep(nanoseconds: Self.guideWait)
            guard !Task.isCancelled else { return }
            finishGuideQuietly()
        }
    }

    private func clicked(at location: CGPoint) {
        guard var session = guide, let tag = session.current, let screen = screen(for: tag) else { return }
        guard session.isHit(click: location, on: screen) else {
            // They've gone off to do something else, so step back without nagging.
            finishGuideQuietly()
            return
        }

        stopWatchingForClick()
        turn?.cancel()
        speechOut.stop()
        overlay.returnToCursor()
        didPoint = false

        let name = session.completeCurrent()
        guide = session
        let task = session.task
        let guidance = session.followUpGuidance()
        setMode(.thinking)
        island.show(.thinking)

        turn = Task {
            do {
                try await Task.sleep(nanoseconds: Self.settleAfterClick)
                try await exchange(transcript: task, guidance: guidance, historyEntry: "(clicked \(name))")
            } catch is CancellationError {
                // Interrupted: whatever interrupted the turn has already reset the state.
            } catch {
                if !Task.isCancelled { show(error) }
            }
        }
    }

    private func finishGuideQuietly() {
        endGuide()
        didPoint = false
        overlay.returnToCursor()
        island.rest()
    }

    private func endGuide() {
        guide = nil
        stopWatchingForClick()
    }

    private func stopWatchingForClick() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guideTimeout?.cancel()
        guideTimeout = nil
    }

    private func show(_ error: Error) {
        NSSound(named: "Basso")?.play()
        endGuide()
        overlay.returnToCursor()
        island.showMessage(error.localizedDescription)
        setMode(.idle)
    }
}

