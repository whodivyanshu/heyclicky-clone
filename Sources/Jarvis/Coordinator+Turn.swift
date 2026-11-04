import AppKit
import JarvisCore

// One round with the AI, from the screenshot to the queued reply.
extension Coordinator {
    func runVoiceTurn() async {
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

    func perform(transcript spoken: String) async {
        if runMeetingCommand(spoken) { return }
        // Saying a routine's phrase asks for what it stands for, in every way after this point.
        var transcript = spoken
        if let request = routineRequest(for: spoken) {
            transcript = request
            let keepsUnattended = unattended
            startRequest(request)
            unattended = keepsUnattended
            if unattended { control = nil }
        }
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
    func runQuickCommand(_ transcript: String) -> Bool {
        guard let tag = QuickCommand.action(
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

        let said = QuickCommand.confirmation(for: tag, hindi: settings.hindiAssistant)
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

    func resetTurnState() {
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
    func exchange(transcript: String, guidance: String?, historyEntry: String, continuesRequest: Bool = false, answeringLookup: Bool = false) async throws {
        self.answeringLookup = answeringLookup
        let onDevice = settings.usesOnDeviceRules
        // Data that was just looked up is all a plain answer needs. A job still in progress has to see where it's up to.
        let looksAtScreen = !unattended
            && (!answeringLookup || control != nil)
            && (!onDevice || OnDeviceRules.needsScreen(transcript))
        onDeviceGuard = onDevice ? OnDeviceGuard(transcript: transcript) : nil
        setMode(.thinking)
        island.reply = ""
        if !looksAtScreen, island.progress.isEmpty { island.progress = "Thinking…" }
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
        latestScreenshot = settings.keepActivityScreenshots ? captured.first?.jpeg : nil
        screens = captured.map(\.map)
        controls = seen.controls

        let request = AIRequest(
            system: onDevice
                ? OnDeviceRules.system(for: transcript, memories: settings.memory.facts)
                : Prompt.system(canControlMac: control != nil, hindi: settings.hindiAssistant, memories: settings.memory.facts, shortcuts: NativeServices.knownShortcuts, screenMemory: settings.screenMemoryEnabled, teachingNotes: teachingNotes()),
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
    var replyKind: String {
        var parts: [String] = []
        if sawTarget { parts.append("guide") }
        if sawPoint { parts.append("point") }
        if ranClickOrKeys { parts.append("click or keys") } else if ranScreenAction { parts.append("open or quit") }
        if sawAction, parts.isEmpty, !wantsNextStep, !sawDone { parts.append("other action") }
        if wantsNextStep { parts.append("next step") }
        if sawDone { parts.append("done") }
        return parts.isEmpty ? "words only" : parts.joined(separator: ", ")
    }

    struct Look {
        var captured: [CapturedScreen] = []
        var controls: [ScreenControl] = []
    }

    /// Takes the screenshot and reads the front window's controls at the same time.
    func look(readsControls: Bool) async throws -> Look {
        let finding = readsControls ? UIInspector.startFindingControls() : nil
        let captured = try await capture()
        let found = await finding?.value ?? []
        return Look(
            captured: captured,
            controls: UIInspector.controls(found, on: captured.map(\.map), primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
        )
    }

    func discardPendingLook() {
        pendingLook?.cancel()
        pendingLook = nil
    }

    func capture() async throws -> [CapturedScreen] {
        guard Permissions.screen else {
            Permissions.requestScreen()
            throw JarvisMessage("Jarvis needs Screen Recording access. Allow it in System Settings, then reopen Jarvis.")
        }
        return try await ScreenCapture.captureAll()
    }

    func userMessage(transcript: String, guidance: String?, captured: [CapturedScreen]) -> String {
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
            controls: controls,
            now: settings.usesOnDeviceRules ? nil : Self.currentTime()
        )
    }

    /// Notes for the app in front of them, when they've asked to learn something.
    private func teachingNotes() -> String? {
        guard settings.teachingEnabled else { return nil }
        return TeachingPack.notes(
            forApp: NSWorkspace.shared.frontmostApplication?.localizedName,
            transcript: requestText,
            packs: TeachingFiles.all()
        )
    }

    /// Both spoken and exact, so the model can write dates in tags without working out the calendar.
    private static func currentTime() -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "EEEE, yyyy-MM-dd'T'HH:mm"
        return format.string(from: Date())
    }

    func deliver(_ beats: [Beat], final: Bool = false) {
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
    func releaseHeldBeats() {
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
}
