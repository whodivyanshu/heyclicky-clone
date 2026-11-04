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
    /// Once something has run this turn the screenshot may be out of date, so a click could land on the wrong thing.
    private var didRunAction = false
    private var actionFailure: String?
    private var isTurnRecorded = false
    private var returnTask: Task<Void, Never>?

    /// Set while a request is running with full control turned on.
    private var control: ControlSession?
    private var wantsNextStep = false
    /// An app or page that was just opened may not be ready, so keys sent now could land in the wrong window.
    private var didOpenSomething = false
    /// The reply was planned for a screen that turned out to be different, so the rest of it is dropped and Jarvis looks again.
    private var abandonedReply = false
    private var sawDone = false
    private var sawTarget = false
    private var ranScreenAction = false
    private var ranClickOrKeys = false
    private var sawPoint = false
    private var madePlan = false
    /// How the screen looked before opening something, to tell when the new window has appeared.
    private var beforeOpening: [UInt8]?
    /// A screenshot started when the shortcut was released, so it's ready by the time the transcript is.
    private var pendingLook: Task<Look, Error>?
    private var clock = TurnClock()
    /// While a job runs, words wait for the end of the reply, and are only spoken if the job is finished.
    private var heldBeats: [Beat] = []
    /// What Jarvis itself typed for this request. Shown when it asks, since this is what would actually be sent.
    private var lastTyped: String?
    /// Only their own new words can change what's remembered, not later steps that follow a screenshot.
    private var isDirectRequest = false
    private var controls: [ScreenControl] = []
    /// Set for a turn on Apple's on-device model, which can't be trusted with everything it asks for.
    private var onDeviceGuard: OnDeviceGuard?

    /// What the model said the next step will do, which also makes that step need a yes.
    private var declaredConfirmation: String?
    private var pendingConfirmation: CheckedContinuation<Bool, Never>?
    private var confirmationTimeout: Task<Void, Never>?
    private var isAnsweringConfirmation = false

    private var guide: GuideSession?
    private var clickMonitor: Any?
    private var guideTimeout: Task<Void, Never>?

    private static let minimumHold: TimeInterval = 0.25
    private static let historyLimit = 6
    /// Silent steps have no words, and an empty turn in the history can be rejected by the provider.
    private static let workingPlaceholder = "Working on it."
    private static let pointHoldAfterSpeech: UInt64 = 2_500_000_000
    /// How long a finished reply stays readable on the island.
    private static let replyLinger: Double = 5
    /// Gives the app time to react to a click before the next screenshot, or less once the screen has stopped changing.
    /// The minimum leaves time for a list to filter or a menu to appear, since a stale screen could mean a wrong click.
    private static let settleAfterClick = (minimum: 0.35, limit: 0.7)
    /// Apps and pages take longer to be ready than a click takes to register.
    private static let settleAfterOpening = (minimum: 0.3, limit: 1.5)
    private static let guideWait: UInt64 = 120_000_000_000
    private static let confirmationWait: UInt64 = 60_000_000_000

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

    private func setMode(_ mode: CompanionMode) {
        self.mode = mode
        overlay.setMode(mode)
        onModeChange(mode)
    }

    // MARK: - Input

    private func pressed() {
        // Holding the shortcut while Jarvis is asking answers the question, rather than stopping the job.
        if pendingConfirmation != nil {
            startAnsweringConfirmation()
            return
        }
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
                try speechIn.start(locale: settings.listeningLocale)
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

        if isAnsweringConfirmation {
            finishAnsweringConfirmation()
            return
        }
        if let pressedAt, Date().timeIntervalSince(pressedAt) < Self.minimumHold {
            // Probably part of another keyboard shortcut.
            speechIn.cancel()
            island.rest()
            setMode(.idle)
            return
        }
        clock.restart()
        // Taken now so it's ready when the transcript is. It stays on this Mac unless the request goes to the model.
        if !settings.usesOnDeviceRules, Permissions.screen {
            pendingLook = Task { try await look(readsControls: true) }
        }
        turn = Task { await runVoiceTurn() }
    }

    /// A typed question or a suggestion from the island's panel.
    private func ask(_ text: String) {
        interrupt()
        island.isOpen = false
        island.rest()
        clock.restart()
        startRequest(text)
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
        // Answers first, so the waiting step can finish. Anything that interrupts a question is a no.
        resolveConfirmation(false)
        turn?.cancel()
        turn = nil
        discardPendingLook()
        returnTask?.cancel()
        returnTask = nil
        endGuide()
        speechIn.cancel()
        speechOut.stop()
        overlay.returnToCursor()
        didPoint = false
        control = nil
        wantsNextStep = false
        heldBeats = []
    }

    private func startRequest(_ text: String) {
        guide = GuideSession(task: text)
        control = settings.controlsMac && !settings.usesOnDeviceRules ? ControlSession(task: text) : nil
        lastTyped = nil
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
            clock.mark("transcript")
            guard !transcript.isEmpty else {
                discardPendingLook()
                island.showMessage("Didn't catch that.", lasting: 2)
                setMode(.idle)
                return
            }
            startRequest(transcript)
            await perform(transcript: transcript)
        } catch is CancellationError {
            // Interrupted: whatever interrupted the turn has already reset the state.
        } catch {
            if !Task.isCancelled { show(error) }
        }
    }

    private func perform(transcript: String) async {
        if runQuickCommand(transcript) { return }
        do {
            try await exchange(transcript: transcript, guidance: nil, historyEntry: transcript)
        } catch is CancellationError {
            // Interrupted: whatever interrupted the turn has already reset the state.
        } catch {
            if !Task.isCancelled { show(error) }
        }
    }

    /// Runs a simple command without asking the model. Returns false if the model should handle it.
    private func runQuickCommand(_ transcript: String) -> Bool {
        // The commands it recognizes are in English, and its replies would be too.
        guard !settings.hindiAssistant, let tag = QuickCommand.action(
            for: transcript,
            installedApps: { ActionRunner.installedAppNames() },
            runningApps: { ActionRunner.runningApps().compactMap(\.localizedName) }
        ) else { return false }
        clock.mark("quick command matched")
        discardPendingLook()
        control = nil
        onDeviceGuard = nil
        resetTurnState()
        allowsActions = true
        isDirectRequest = true

        let said = QuickCommand.confirmation(for: tag)
        island.reply = said
        setMode(.speaking)
        island.show(.speaking)
        speechOut.begin()
        speechOut.enqueue([.action(tag), .say(said)])
        history = Array((history + [ChatTurn(user: transcript, assistant: said)]).suffix(Self.historyLimit))
        island.conversation = history
        isTurnRecorded = true
        speechOut.finishInput()
        return true
    }

    private func resetTurnState() {
        island.notice = ""
        island.activity = ""
        sawAction = false
        didRunAction = false
        didOpenSomething = false
        wantsNextStep = false
        actionFailure = nil
        isTurnRecorded = false
        abandonedReply = false
        sawDone = false
        sawTarget = false
        ranScreenAction = false
        ranClickOrKeys = false
        sawPoint = false
        madePlan = false
        beforeOpening = nil
        heldBeats = []
        declaredConfirmation = nil
    }

    /// One round with the AI: takes fresh screenshots, streams the reply, and hands it to speech.
    /// `continuesRequest` marks a later step of a request Jarvis is carrying out by itself.
    private func exchange(transcript: String, guidance: String?, historyEntry: String, continuesRequest: Bool = false) async throws {
        let onDevice = settings.usesOnDeviceRules
        let looksAtScreen = !onDevice || OnDeviceRules.needsScreen(transcript)
        onDeviceGuard = onDevice ? OnDeviceGuard(transcript: transcript) : nil
        setMode(.thinking)
        island.reply = ""
        if !looksAtScreen { island.progress = "Thinking…" }
        island.show(.thinking)
        // Walkthrough follow-ups have no new words from the user, so only a direct request can act,
        // along with the later steps of a request they gave Jarvis to carry out.
        allowsActions = guidance == nil || continuesRequest
        isDirectRequest = guidance == nil
        resetTurnState()

        let provider = try settings.makeProvider()
        let seen: Look
        if !looksAtScreen {
            seen = Look()
        } else if let pendingLook {
            self.pendingLook = nil
            seen = try await pendingLook.value
        } else {
            seen = try await look(readsControls: !onDevice)
        }
        try Task.checkCancellation()
        clock.mark("screen and controls")
        let captured = seen.captured
        screens = captured.map(\.map)
        controls = seen.controls

        let request = AIRequest(
            system: onDevice
                ? OnDeviceRules.system(for: transcript, memories: settings.memory.facts)
                : Prompt.system(canControlMac: control != nil, hindi: settings.hindiAssistant, memories: settings.memory.facts),
            history: history,
            userText: userMessage(transcript: transcript, guidance: guidance, captured: captured),
            jpegImages: captured.map(\.jpeg)
        )

        var parser = ResponseParser()
        var reply = ""
        speechOut.begin()
        for try await chunk in provider.stream(request) {
            try Task.checkCancellation()
            if reply.isEmpty { clock.mark("model first text") }
            reply += chunk
            deliver(parser.feed(chunk))
        }
        try Task.checkCancellation()
        deliver(parser.finish(), final: true)
        clock.mark("model finished")
        if let control, allowsActions, ranScreenAction, !sawDone, !sawTarget,
           control.needsAnotherLook(ranClickOrKeys: ranClickOrKeys, madePlan: madePlan) {
            // It acted without saying it was finished, so look at the result instead of stopping partway through.
            wantsNextStep = true
        }
        clock.mark("reply was \(replyKind)")
        releaseHeldBeats()

        let spoken = onDeviceGuard?.spoken ?? ResponseParser.spokenText(of: reply)
        if spoken.isEmpty, !didPoint, !sawAction {
            throw JarvisMessage(onDevice ? "Sorry, I didn't get that. Try asking another way." : "The model sent back an empty reply.")
        }
        let said = actionFailure ?? (abandonedReply ? "" : spoken)
        if continuesRequest, let last = history.last {
            // One request stays one turn, however many steps it took, so it doesn't push out the conversation.
            let earlier = last.assistant == Self.workingPlaceholder ? "" : last.assistant
            let merged = [earlier, said].filter { !$0.isEmpty }.joined(separator: " ")
            history[history.count - 1] = ChatTurn(user: last.user, assistant: merged.isEmpty ? Self.workingPlaceholder : merged)
        } else {
            history.append(ChatTurn(user: historyEntry, assistant: said.isEmpty ? Self.workingPlaceholder : said))
        }
        history = Array(history.suffix(Self.historyLimit))
        island.conversation = history
        isTurnRecorded = true
        speechOut.finishInput()
    }

    /// How the reply ended, for the timing log. It never includes what was said.
    private var replyKind: String {
        var parts: [String] = []
        if sawTarget { parts.append("guide") }
        if sawPoint { parts.append("point") }
        if ranClickOrKeys { parts.append("click or keys") } else if ranScreenAction { parts.append("open or quit") }
        if sawAction, parts.isEmpty, !wantsNextStep, !sawDone { parts.append("other action") }
        if wantsNextStep { parts.append("next step") }
        if sawDone { parts.append("done") }
        return parts.isEmpty ? "words only" : parts.joined(separator: ", ")
    }

    private struct Look {
        var captured: [CapturedScreen] = []
        var controls: [ScreenControl] = []
    }

    /// Takes the screenshot and reads the front window's controls at the same time.
    private func look(readsControls: Bool) async throws -> Look {
        let finding = readsControls ? UIInspector.startFindingControls() : nil
        let captured = try await capture()
        let found = await finding?.value ?? []
        return Look(
            captured: captured,
            controls: UIInspector.controls(found, on: captured.map(\.map), primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
        )
    }

    private func discardPendingLook() {
        pendingLook?.cancel()
        pendingLook = nil
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
            frontmostApp: NSWorkspace.shared.frontmostApplication?.localizedName,
            selection: guidance == nil ? UIInspector.selectedText() : nil,
            clipboard: guidance == nil && ContextRules.mentionsClipboard(transcript) ? ActionRunner.clipboardText() : nil,
            controls: controls
        )
    }

    private func deliver(_ beats: [Beat], final: Bool = false) {
        let beats = onDeviceGuard?.filter(beats, final: final) ?? beats
        guard !beats.isEmpty else { return }
        if mode != .speaking { setMode(.speaking) }
        var now: [Beat] = []
        for beat in beats {
            switch beat {
            case .say(let text):
                guard actionFailure == nil, !abandonedReply else { continue }
                island.reply += island.reply.isEmpty ? text : " " + text
            case .action(let tag):
                sawAction = true
                if tag.kind == .plan { madePlan = true }
                if tag.kind.changesScreen {
                    ranScreenAction = true
                    if !tag.kind.canFinishRequest { ranClickOrKeys = true }
                }
            case .click:
                sawAction = true
                ranScreenAction = true
                ranClickOrKeys = true
            case .next:
                sawAction = true
                wantsNextStep = allowsActions && control != nil
            case .done:
                sawAction = true
                sawDone = true
            case .target:
                sawTarget = true
            case .point:
                sawPoint = true
            }
            // Actions run right away. Pointing stays in step with the words around it.
            switch beat {
            case .say, .point, .target:
                if control != nil { heldBeats.append(beat) } else { now.append(beat) }
            case .action, .click, .next, .done:
                now.append(beat)
            }
        }
        if island.phase == .thinking { island.show(.speaking) }
        speechOut.enqueue(now)
    }

    /// Jarvis works silently, so words are spoken only once there's nothing left to do.
    private func releaseHeldBeats() {
        var beats = heldBeats
        heldBeats = []
        if wantsNextStep {
            beats.removeAll { if case .say = $0 { return true } else { return false } }
        } else if control != nil, sawDone, !beats.contains(where: { if case .say = $0 { return true } else { return false } }) {
            let word = settings.hindiAssistant ? "हो गया।" : "Done."
            island.reply = word
            beats.append(.say(word))
        }
        speechOut.enqueue(beats)
    }

    /// Returns what to say instead of the model's reply if the action failed.
    private func act(_ tag: ActionTag) async -> String? {
        // After a failure the rest of the reply was planned for a screen that isn't there.
        guard allowsActions, actionFailure == nil, !abandonedReply else { return nil }
        switch tag.kind {
        case .plan:
            control?.setPlan(tag.value)
            return nil
        case .confirm:
            declaredConfirmation = tag.value
            return nil
        case .remember:
            guard isDirectRequest, let saved = settings.memory.add(tag.value) else { return nil }
            island.activity = "Remembered: \(saved)"
            return nil
        case .forget:
            guard isDirectRequest else { return nil }
            island.activity = settings.memory.forget(matching: tag.value).isEmpty ? "Nothing saved about that" : "Forgot that"
            return nil
        case .copy:
            island.activity = ActionRunner.progress(for: tag)
            return report(await ActionRunner.run(tag))
        default:
            break
        }

        if tag.kind.usesKeyboard {
            guard control != nil else {
                return report(ActionResult(summary: "Didn't type", failure: "I can't use your keyboard unless you turn on full control in Settings."))
            }
            guard !didOpenSomething else {
                return report(ActionResult(summary: "Didn't type", failure: "The new window may not have been ready, so I stopped before typing. Ask me again and I'll take a fresh look.", retryable: true))
            }
        } else {
            didOpenSomething = true
        }

        let needsYes: Bool
        var title = String(ActionRunner.progress(for: tag).dropLast())
        if tag.kind == .pressKey {
            let context = UIInspector.keyContext()
            needsYes = declaredConfirmation != nil || RiskRules.keyNeedsConfirmation(tag.value, context: context)
            title = "Press \(tag.value) in \(context.appName)"
        } else {
            needsYes = declaredConfirmation != nil
        }
        if needsYes {
            let app = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let approved = await askToConfirm(title)
            guard !Task.isCancelled else { return nil }
            guard approved else { return declined() }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app else { return screenChanged() }
        }

        didRunAction = true
        island.activity = ActionRunner.progress(for: tag)
        if control != nil, !tag.kind.usesKeyboard {
            beforeOpening = await ScreenCapture.thumbnail()
            guard !Task.isCancelled else { return nil }
        }
        let result = await ActionRunner.run(tag)
        clock.mark("ran \(tag.kind.rawValue)")
        if result.failure == nil, tag.kind == .typeText || tag.kind == .paste { lastTyped = tag.value }
        return report(result)
    }

    /// Flies the pointer to the target so they can see what's about to happen, then clicks it.
    private func click(_ tag: PointTag) async -> String? {
        // Walkthrough follow-ups have no new words from the user, so show the target and leave the click to them.
        guard allowsActions else {
            point(at: tag)
            return nil
        }
        guard actionFailure == nil, !abandonedReply else { return nil }
        let tag = ControlMatcher.snap(tag, to: controls)
        guard !didRunAction, let screen = screen(for: tag) else {
            return report(ActionResult(
                summary: "Didn't click \(tag.label ?? "that")",
                failure: "The screen may have changed, so I didn't click. Ask me again and I'll take a fresh look.",
                retryable: true
            ))
        }
        didRunAction = true
        didPoint = true
        island.activity = "Clicking \(tag.label ?? "that")…"
        let location = screen.globalPoint(imageX: tag.x, imageY: tag.y)
        let flight = overlay.fly(to: location, label: tag.label)
        try? await Task.sleep(nanoseconds: UInt64(flight * 1_000_000_000))
        // Esc or the shortcut during the flight has to stop the click.
        guard !Task.isCancelled else { return nil }

        // What the app calls the control counts as much as what the model calls it.
        let quartz = Geometry.quartzPoint(appKit: location, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
        let labels = UIInspector.labels(at: quartz)
        let risky = RiskRules.riskyLabel(in: labels + [tag.label].compactMap { $0 })
        if risky != nil || declaredConfirmation != nil {
            let app = NSWorkspace.shared.frontmostApplication
            let name = risky ?? labels.first ?? tag.label ?? "that"
            let approved = await askToConfirm("Click \"\(name)\" in \(app?.localizedName ?? "this app")")
            guard !Task.isCancelled else { return nil }
            guard approved else { return declined() }
            // Whatever they approved has to still be what's under the pointer.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app?.processIdentifier,
                  UIInspector.labels(at: quartz) == labels
            else { return screenChanged() }
        }

        let result = await ActionRunner.click(at: location, label: tag.label)
        guard !Task.isCancelled else { return nil }
        return report(result)
    }

    // MARK: - Confirmation

    /// Waits for a yes. The answer comes only from their voice, the island's buttons or Esc, so the model can't answer for them.
    private func askToConfirm(_ title: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        let summary = declaredConfirmation
        declaredConfirmation = nil

        island.confirmTitle = title
        island.confirmDetail = [summary, lastTyped.map { "Typed: \($0.prefix(200))" }].compactMap { $0 }.joined(separator: "\n")
        island.notice = ""
        island.show(.confirming)
        NSSound(named: "Tink")?.play()
        if settings.hindiAssistant {
            speechOut.announce("\(summary ?? title)। क्या मैं कर दूँ?")
        } else {
            speechOut.announce(summary.map { "\($0). Should I go ahead?" } ?? "\(title). Should I go ahead?")
        }

        let approved = await withCheckedContinuation { continuation in
            pendingConfirmation = continuation
            confirmationTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.confirmationWait)
                guard !Task.isCancelled else { return }
                self?.resolveConfirmation(false)
            }
        }
        guard !Task.isCancelled else { return false }
        island.confirmTitle = ""
        island.confirmDetail = ""
        island.notice = ""
        island.show(.speaking)
        return approved
    }

    private func resolveConfirmation(_ approved: Bool) {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        confirmationTimeout?.cancel()
        confirmationTimeout = nil
        if isAnsweringConfirmation {
            isAnsweringConfirmation = false
            isListening = false
            speechIn.cancel()
        }
        speechOut.stopAnnouncement()
        pending.resume(returning: approved)
    }

    private func startAnsweringConfirmation() {
        speechOut.stopAnnouncement()
        isAnsweringConfirmation = true
        isListening = true
        pressedAt = Date()
        island.transcript = ""
        island.show(.listening)
        Task {
            guard await ensureVoicePermissions(), isListening else { return }
            do {
                try speechIn.start(locale: settings.listeningLocale)
            } catch {
                island.notice = error.localizedDescription
                isListening = false
                isAnsweringConfirmation = false
                island.show(.confirming)
            }
        }
    }

    private func finishAnsweringConfirmation() {
        isAnsweringConfirmation = false
        if let pressedAt, Date().timeIntervalSince(pressedAt) < Self.minimumHold {
            speechIn.cancel()
            island.show(.confirming)
            return
        }
        Task {
            let answer = (try? await speechIn.stop()) ?? ""
            guard pendingConfirmation != nil else { return }
            if let decision = ConfirmationRules.decision(from: answer) {
                resolveConfirmation(decision)
            } else {
                island.notice = "I didn't catch a yes or no."
                island.show(.confirming)
            }
        }
    }

    private func declined() -> String? {
        report(ActionResult(summary: "Left that to you", failure: settings.hindiAssistant ? "ठीक है, मैंने वह नहीं किया।" : "Okay, I didn't do that."))
    }

    private func screenChanged() -> String? {
        report(ActionResult(summary: "Stopped", failure: "The screen changed while I was asking, so I didn't do it."))
    }

    private func report(_ result: ActionResult) -> String? {
        // A failure is explained in the reply itself, so only success gets the checkmark line.
        island.activity = result.failure == nil ? result.summary : ""
        guard let failure = result.failure else {
            control?.record(result.summary)
            return nil
        }
        if result.retryable, var session = control, session.recordFailure(failure) {
            control = session
            abandonedReply = true
            wantsNextStep = true
            heldBeats = []
            return ""
        }
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
        if continueRequest() { return }
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

    // MARK: - Full control

    /// Starts the next step if the model asked for one. A failed action ends the request.
    private func continueRequest() -> Bool {
        guard wantsNextStep, actionFailure == nil, var session = control else { return false }
        wantsNextStep = false
        didPoint = false
        overlay.returnToCursor()

        guard session.advance() else {
            control = nil
            speechOut.begin()
            speechOut.enqueue([.say("I've stopped after \(ControlSession.maxSteps) steps. Ask me again if there's more to do.")])
            island.reply = "I've stopped after \(ControlSession.maxSteps) steps. Ask me again if there's more to do."
            island.show(.speaking)
            speechOut.finishInput()
            return true
        }
        control = session
        let task = session.task
        let guidance = session.followUpGuidance()
        let opened = didOpenSomething
        let before = beforeOpening
        // A reply with nothing but NEXT is waiting for something to load, and that can look settled until it arrives.
        let ranSomething = ranScreenAction
        island.progress = ["Step \(session.step)", session.plan].compactMap { $0 }.joined(separator: ": ")
        setMode(.thinking)
        island.show(.thinking)
        turn = Task {
            do {
                if opened {
                    try await ScreenCapture.waitUntilSettled(
                        mustChangeFrom: before, requiresChange: true,
                        atLeast: Self.settleAfterOpening.minimum, limit: Self.settleAfterOpening.limit
                    )
                } else {
                    let settle = Self.settleAfterClick
                    try await ScreenCapture.waitUntilSettled(atLeast: ranSomething ? settle.minimum : settle.limit, limit: settle.limit)
                }
                clock.mark("waited for the screen")
                try await exchange(transcript: task, guidance: guidance, historyEntry: task, continuesRequest: true)
            } catch is CancellationError {
                // Interrupted: whatever interrupted the turn has already reset the state.
            } catch {
                if !Task.isCancelled { show(error) }
            }
        }
        return true
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
                try await ScreenCapture.waitUntilSettled(atLeast: Self.settleAfterClick.minimum, limit: Self.settleAfterClick.limit)
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

