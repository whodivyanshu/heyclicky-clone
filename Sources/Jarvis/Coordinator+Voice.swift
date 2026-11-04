import AppKit
import JarvisCore

// Dictation, talking over Jarvis, meeting notes and requests from Shortcuts.
extension Coordinator {
    private static let longestMeeting: UInt64 = 3 * 60 * 60 * 1_000_000_000

    func startVoiceFeatures() {
        hotkeys.dictationHotkey = { [settings] in settings.dictationHotkey.flags }
        hotkeys.onDictationPress = { [weak self] in self?.dictationPressed() }
        hotkeys.onDictationRelease = { [weak self] in self?.dictationReleased() }

        bargeIn.speaking = { [weak self] in self?.island.reply ?? "" }
        bargeIn.onStop = { [weak self] in self?.escape() }
        bargeIn.onInterrupt = { [weak self] in self?.bargeHeard() }
        bargeIn.onPartial = { [weak self] text in
            guard let self, self.isBargeCapturing else { return }
            self.island.transcript = text
        }
        bargeIn.onCommand = { [weak self] in self?.bargeCommand($0) }

        meetingRecorder.onLine = { [weak self] in self?.addMeetingLine($0) }
        IntentBridge.handler = { [weak self] in await self?.askFromShortcut($0) ?? "Jarvis isn't ready yet." }
    }

    // MARK: - Dictation

    private func dictationPressed() {
        guard pendingConfirmation == nil else { return }
        interrupt()
        lastTurnWasVoice = false
        isDictating = true
        isListening = true
        pressedAt = Date()
        island.isOpen = false
        setMode(.listening)
        island.rest()
        island.show(.listening)
        Task {
            guard await ensureVoicePermissions() else {
                isDictating = false
                isListening = false
                return
            }
            guard isDictating else { return }
            do {
                try speechIn.start(locale: settings.dictationLocale)
            } catch {
                isDictating = false
                isListening = false
                show(error)
            }
        }
    }

    private func dictationReleased() {
        guard isDictating else { return }
        isDictating = false
        isListening = false
        overlay.setLevel(0)
        island.level = 0
        if let pressedAt, Date().timeIntervalSince(pressedAt) < Self.minimumHold {
            speechIn.cancel()
            island.rest()
            setMode(.idle)
            return
        }
        turn = Task {
            do {
                let heard = try await speechIn.stop()
                try Task.checkCancellation()
                let text = DictationRules.withoutFillers(heard)
                guard !text.isEmpty else {
                    island.showMessage("Didn't catch that.", lasting: 2)
                    setMode(.idle)
                    return
                }
                let finished = settings.dictationCleanup ? await cleanedUp(text) : text
                try Task.checkCancellation()
                let result = await ActionRunner.insertDictation(finished)
                guard !Task.isCancelled else { return }
                if settings.keepActivityLog {
                    // How much, rather than what. Dictation is often private, and they're looking right at it.
                    let count = finished.split(whereSeparator: \.isWhitespace).count
                    settings.activity.add(request: "Dictation", summary: "Dictated \(count) words", failure: result.failure, screenshot: nil)
                }
                if let failure = result.failure {
                    island.showMessage(failure)
                } else {
                    island.rest()
                }
                setMode(.idle)
            } catch is CancellationError {
                // Interrupted: whatever interrupted the turn has already reset the state.
            } catch {
                if !Task.isCancelled { show(error) }
            }
        }
    }

    /// Uses the chosen AI, and falls back to their own words if that doesn't work.
    private func cleanedUp(_ text: String) async -> String {
        island.progress = settings.hindiAssistant ? "ठीक कर रहा हूँ…" : "Cleaning that up…"
        setMode(.thinking)
        island.show(.thinking)
        do {
            let provider = try settings.makeProvider()
            var cleaned = ""
            for try await chunk in provider.stream(AIRequest(system: DictationRules.cleanupSystem, userText: text)) {
                cleaned += chunk
            }
            return DictationRules.accepted(cleaned: cleaned, original: text)
        } catch {
            return text
        }
    }

    // MARK: - Talking over Jarvis

    /// Listens only while Jarvis has something to say, and not during a meeting, which already has the microphone.
    func updateBargeIn() {
        guard settings.bargeInEnabled, mode == .speaking, !meetingRecorder.isRecording,
              Permissions.microphone, Permissions.speech
        else {
            if !isBargeCapturing { bargeIn.stop() }
            return
        }
        guard OnDeviceRecognition.isSupported(locale: settings.listeningLocale) else { return }
        do {
            try bargeIn.start(locale: settings.listeningLocale)
        } catch {
            island.notice = error.localizedDescription
        }
    }

    private func bargeHeard() {
        // A yes or no comes only from the shortcut or the buttons, so talking can't answer for them.
        guard pendingConfirmation == nil else {
            bargeIn.stop()
            return
        }
        interrupt()
        isBargeCapturing = true
        lastTurnWasVoice = true
        island.rest()
        setMode(.listening)
        island.show(.listening)
    }

    private func bargeCommand(_ command: String) {
        guard isBargeCapturing else { return }
        isBargeCapturing = false
        guard !command.isEmpty else {
            island.rest()
            setMode(.idle)
            return
        }
        ask(command, byVoice: true)
    }

    // MARK: - Meeting notes

    var isRecordingMeeting: Bool { meetingRecorder.isRecording }

    func toggleMeeting() {
        Task {
            if isRecordingMeeting {
                await stopMeeting()
            } else {
                await startMeeting()
            }
        }
    }

    /// A whole sentence that starts or stops a meeting, handled here so the AI can never start a recording.
    func runMeetingCommand(_ transcript: String) -> Bool {
        guard let command = MeetingRules.command(in: transcript) else { return false }
        discardPendingLook()
        island.rest()
        setMode(.idle)
        Task {
            switch command {
            case .start: await startMeeting()
            case .stop: await stopMeeting()
            }
        }
        return true
    }

    private func startMeeting() async {
        guard !isRecordingMeeting, await ensureVoicePermissions() else { return }
        guard Permissions.screen else {
            Permissions.requestScreen()
            island.showMessage("Meeting notes need Screen Recording access to hear the call. Allow it in System Settings, then reopen Jarvis.")
            return
        }
        // Nobody else's audio can start being processed by this while the wake word still holds the microphone.
        wakeWordUpdate?.cancel()
        wakeWord.stop()
        do {
            try await meetingRecorder.start(locale: settings.listeningLocale)
        } catch {
            island.showMessage(error.localizedDescription)
            updateWakeWord()
            return
        }
        currentMeeting = MeetingNote(start: Date())
        settings.meetings.save(currentMeeting!)
        island.isRecordingMeeting = true
        onMeetingChange(true)
        island.showMessage("Taking meeting notes. Let everyone on the call know. Say \"stop meeting notes\" when you're done.", lasting: 6)
        meetingLimit = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.longestMeeting)
            guard !Task.isCancelled else { return }
            await self?.stopMeeting()
        }
    }

    private func addMeetingLine(_ line: MeetingLine) {
        guard var note = currentMeeting else { return }
        note.lines.append(line)
        currentMeeting = note
        // Saved as it goes, so a crash doesn't lose the meeting.
        settings.meetings.save(note)
    }

    private func stopMeeting() async {
        guard isRecordingMeeting else { return }
        meetingLimit?.cancel()
        await meetingRecorder.stop()
        island.isRecordingMeeting = false
        onMeetingChange(false)
        updateWakeWord()
        guard var note = currentMeeting else { return }
        currentMeeting = nil
        note.end = Date()
        settings.meetings.save(note)
        guard !note.lines.isEmpty else {
            island.showMessage("I didn't hear anything to take notes on.")
            settings.meetings.remove(id: note.id)
            return
        }
        island.showMessage("Summarizing the meeting…", lasting: 4)
        await summarize(note)
        island.showMessage("Your meeting notes are ready in Settings, under Meetings.")
    }

    /// The reply is only ever saved as text. It's never read for action tags, because the words came from a call.
    func summarize(_ original: MeetingNote) async {
        var note = original
        do {
            let provider = try settings.makeProvider()
            var summary = ""
            for try await chunk in provider.stream(MeetingRules.summaryRequest(transcript: note.transcript, hindi: settings.hindiAssistant)) {
                summary += chunk
            }
            note.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            note.problem = nil
        } catch {
            note.problem = "Couldn't summarize this: \(error.localizedDescription)"
        }
        settings.meetings.save(note)
    }

    // MARK: - Shortcuts and Siri

    /// Runs like a typed question, then hands back the final reply.
    func askFromShortcut(_ text: String) async -> String {
        await withCheckedContinuation { continuation in
            ask(text)
            shortcutReply = continuation
        }
    }

    func finishShortcut(with reply: String) {
        shortcutReply?.resume(returning: reply)
        shortcutReply = nil
    }
}
