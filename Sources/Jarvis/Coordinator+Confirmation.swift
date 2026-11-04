import AppKit
import JarvisCore

// Asking for a yes before a step that is hard to take back.
extension Coordinator {
    /// Waits for a yes. The answer comes only from their voice, the island's buttons or Esc, so the model can't answer for them.
    func askToConfirm(_ title: String) async -> Bool {
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

    func resolveConfirmation(_ approved: Bool) {
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

    func startAnsweringConfirmation() {
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

    func finishAnsweringConfirmation() {
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
}
