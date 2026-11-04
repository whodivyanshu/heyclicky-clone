import AppKit
import Carbon.HIToolbox
import Combine
import JarvisCore

// Everything that starts without the shortcut: "hey Jarvis", follow-ups, routines and offers of help.
extension Coordinator {
    private static let followUpWindow: TimeInterval = 6
    private static let followUpSilence: TimeInterval = 1.1
    private static let followUpLongest: TimeInterval = 30
    private static let offerLasts: Double = 15
    private static let watchEvery: TimeInterval = 20
    private static let routineCheckEvery: TimeInterval = 20

    func startAutomation() {
        wakeWord.onWake = { [weak self] in self?.wakeHeard() }
        wakeWord.onPartial = { [weak self] text in
            guard let self, self.isWakeCapturing else { return }
            self.island.transcript = text
        }
        wakeWord.onCommand = { [weak self] in self?.wakeCommand($0) }

        // Any of these can change whether the microphone should be open.
        settings.$wakeWordEnabled.dropFirst().sink { [weak self] enabled in
            // This runs just before the setting changes, so a switch-off can't rely on reading it.
            if enabled {
                self?.enableWakeWord()
            } else {
                self?.wakeWordUpdate?.cancel()
                self?.wakeWord.stop()
            }
        }.store(in: &subscriptions)
        settings.$hindiAssistant.dropFirst().sink { [weak self] _ in
            self?.wakeWord.stop()
            self?.updateWakeWord()
        }.store(in: &subscriptions)
        updateWakeWord()

        NativeServices.refreshShortcuts()
        let routines = Timer(timeInterval: Self.routineCheckEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runDueRoutine() }
        }
        let watcher = Timer(timeInterval: Self.watchEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchScreen() }
        }
        RunLoop.main.add(routines, forMode: .common)
        RunLoop.main.add(watcher, forMode: .common)
        island.onAcceptOffer = { [weak self] in
            guard let self else { return }
            self.ask(self.settings.hindiAssistant
                ? "मेरी स्क्रीन पर जो समस्या दिख रही है उसे समझाइए और बताइए कि इसे कैसे ठीक करूँ।"
                : "Explain the problem showing on my screen and how to fix it.")
        }
        island.onDismissOffer = { [weak self] in self?.island.rest() }
    }

    private var isFree: Bool {
        mode == .idle && !isListening && !isWakeCapturing && guide == nil && pendingConfirmation == nil
    }

    private static var isScreenLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // MARK: - Hey Jarvis

    private func enableWakeWord() {
        Task {
            guard await ensureVoicePermissions() else {
                settings.wakeWordEnabled = false
                return
            }
            guard WakeWordListener.isSupported(locale: settings.listeningLocale) else {
                settings.wakeWordEnabled = false
                island.showMessage("\"Hey Jarvis\" needs on-device speech recognition, which this language doesn't have on this Mac.")
                return
            }
            updateWakeWord()
        }
    }

    /// The microphone stays open only while Jarvis is idle, so it can't hear itself or take over from the shortcut.
    func updateWakeWord() {
        wakeWordUpdate?.cancel()
        guard settings.wakeWordEnabled, !meetingRecorder.isRecording, Permissions.microphone, Permissions.speech else {
            wakeWord.stop()
            return
        }
        guard mode == .idle else {
            if !isWakeCapturing { wakeWord.stop() }
            return
        }
        // A short wait avoids restarting between turns, and lets the end of the last word fade out of the room.
        wakeWordUpdate = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self, self.settings.wakeWordEnabled, self.mode == .idle, !self.isListening else { return }
            do {
                try self.wakeWord.start(locale: self.settings.listeningLocale)
            } catch {
                self.settings.wakeWordEnabled = false
                self.show(error)
            }
        }
    }

    private func wakeHeard() {
        guard isFree else { return }
        isWakeCapturing = true
        lastTurnWasVoice = true
        NSSound(named: "Pop")?.play()
        island.rest()
        island.show(.listening)
    }

    private func wakeCommand(_ command: String) {
        guard isWakeCapturing else { return }
        isWakeCapturing = false
        guard !command.isEmpty else {
            island.rest()
            updateWakeWord()
            return
        }
        ask(command, byVoice: true)
    }

    // MARK: - Follow-ups

    /// Keeps listening for a moment after a spoken reply, so they can carry on without the shortcut.
    func listenForFollowUp() {
        guard settings.followUpEnabled, lastTurnWasVoice, actionFailure == nil, !unattended,
              Permissions.microphone, Permissions.speech
        else { return }
        wakeWordUpdate?.cancel()
        turn = Task {
            // The last word of the reply is still in the room.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, isFree else { return }
            isFollowingUp = true
            isListening = true
            followUpHeardAt = nil
            setMode(.listening)
            island.transcript = ""
            island.show(.listening)
            do {
                try speechIn.start(locale: settings.listeningLocale)
            } catch {
                endFollowUpQuietly()
                return
            }

            let started = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                let now = Date()
                if let heard = followUpHeardAt {
                    if now.timeIntervalSince(heard) >= Self.followUpSilence || now.timeIntervalSince(started) >= Self.followUpLongest { break }
                } else if now.timeIntervalSince(started) >= Self.followUpWindow {
                    speechIn.cancel()
                    endFollowUpQuietly()
                    return
                }
            }
            guard !Task.isCancelled else { return }

            isFollowingUp = false
            isListening = false
            overlay.setLevel(0)
            island.level = 0
            let text = (try? await speechIn.stop()) ?? ""
            guard !Task.isCancelled else { return }
            guard !text.isEmpty, !FollowUpRules.endsConversation(text) else {
                endFollowUpQuietly()
                return
            }
            clock.restart()
            startRequest(text)
            await perform(transcript: text)
        }
    }

    private func endFollowUpQuietly() {
        isFollowingUp = false
        isListening = false
        overlay.setLevel(0)
        island.rest()
        setMode(.idle)
    }

    // MARK: - Routines

    /// Called for each request, so saying a routine's phrase runs what it stands for.
    func routineRequest(for transcript: String) -> String? {
        settings.routines.book.routine(matching: transcript)?.request
    }

    func actOnRoutine(_ tag: ActionTag) -> String? {
        guard isDirectRequest else { return nil }
        switch tag.kind {
        case .addRoutine:
            guard let routine = Routine.parse(tag.value) else {
                return report(ActionResult(summary: "Didn't save the routine", failure: "I couldn't work out when that routine should run."))
            }
            guard settings.routines.add(routine) else {
                return report(ActionResult(summary: "Didn't save the routine", failure: "You already have as many routines as I can keep. Delete one in Settings first."))
            }
            return report(ActionResult(summary: "Saved the routine \(routine.name)"))
        default:
            guard let removed = settings.routines.remove(named: tag.value) else {
                return report(ActionResult(summary: "No routine called \(tag.value)", failure: "You don't have a routine called \(tag.value)."))
            }
            return report(ActionResult(summary: "Deleted the routine \(removed.name)"))
        }
    }

    /// A scheduled routine may run with nobody at the Mac, so it never sees the screen or uses the mouse and keyboard.
    /// A routine that can't run yet is tried again until its time has passed.
    private func runDueRoutine() {
        guard isFree, island.phase == .resting, !island.isOpen, !Self.isScreenLocked,
              let routine = settings.routines.book.due(at: Date()).first
        else { return }
        settings.routines.markRan(routine.id, at: Date())
        interrupt()
        island.rest()
        clock.restart()
        lastTurnWasVoice = false
        startRequest(routine.request)
        control = nil
        unattended = true
        turn = Task { await perform(transcript: routine.request) }
    }

    // MARK: - Offers of help

    /// Reads the screen on this Mac, to remember it or to offer help, if they've turned either on.
    /// Offers send nothing anywhere unless accepted, and memory stays on this Mac until they ask about it.
    private func watchScreen() {
        let remembers = settings.screenMemoryEnabled
        let offers = settings.screenWatchEnabled
        guard remembers || offers, Permissions.screen, !isWatching, !Self.isScreenLocked, !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication?.localizedName, settings.appPolicy.permits(appName: app)
        else { return }
        let isPrivate = ScreenMemoryRules.isPrivate(appName: app, windowTitle: UIInspector.keyContext().windowTitle)
        isWatching = true
        Task {
            defer { isWatching = false }
            let thumbnail = await ScreenCapture.thumbnail()
            // An unchanged screen was already read, which saves the work of reading it again.
            if let thumbnail, let lastWatched, ScreenRules.looksSame(thumbnail, lastWatched) { return }
            lastWatched = thumbnail
            guard let text = await ScreenCapture.readText() else { return }
            if remembers, !isPrivate {
                settings.screenMemory.remember(text, app: app, keepingDays: settings.screenMemoryDays)
            }
            guard offers, isFree, island.phase == .resting, !island.isOpen,
                  let offer = watchRules.offer(forScreenText: text, now: Date())
            else { return }
            island.offerTitle = offer
            island.show(.offering)
            island.rest(after: Self.offerLasts)
        }
    }
}
