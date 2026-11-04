import AppKit
import JarvisCore

// Hold-to-talk, typed questions and stopping.
extension Coordinator {
    func pressed() {
        // Holding the shortcut while Jarvis is asking answers the question, rather than stopping the job.
        if pendingConfirmation != nil {
            startAnsweringConfirmation()
            return
        }
        interrupt()
        lastTurnWasVoice = true
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

    func released() {
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
    func ask(_ text: String, byVoice: Bool = false) {
        interrupt()
        lastTurnWasVoice = byVoice
        island.isOpen = false
        island.rest()
        clock.restart()
        startRequest(text)
        turn = Task { await perform(transcript: text) }
    }

    func escape() {
        guard mode != .idle || guide != nil || island.phase != .resting else { return }
        isListening = false
        interrupt()
        overlay.setCaption(nil)
        overlay.setLevel(0)
        island.rest()
        setMode(.idle)
    }

    func interrupt() {
        // Answers first, so the waiting step can finish. Anything that interrupts a question is a no.
        resolveConfirmation(false)
        turn?.cancel()
        turn = nil
        // Stop first, so the microphone isn't still open when the shortcut's own listening starts.
        if isWakeCapturing { wakeWord.stop() }
        isWakeCapturing = false
        if isBargeCapturing { bargeIn.stop() }
        isBargeCapturing = false
        if isDictating { isListening = false }
        isDictating = false
        finishShortcut(with: "Stopped.")
        if isFollowingUp { isListening = false }
        isFollowingUp = false
        lookupResults = []
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

    func startRequest(_ text: String) {
        guide = GuideSession(task: text)
        control = settings.controlsMac && !settings.usesOnDeviceRules ? ControlSession(task: text) : nil
        lastTyped = nil
        requestText = text
        conversationID = UUID()
        lookupResults = []
        lookupRounds = 0
        answeringLookup = false
        unattended = false
        latestScreenshot = nil
    }

    func ensureVoicePermissions() async -> Bool {
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
}
