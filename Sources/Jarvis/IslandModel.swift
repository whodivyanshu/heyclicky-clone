import AppKit
import Combine
import JarvisCore

enum IslandPhase: Equatable {
    case resting, listening, thinking, speaking, guiding, confirming, message, offering
}

/// Everything the island shows. The coordinator writes to it, and the view and window controller read from it.
@MainActor
final class IslandModel: ObservableObject {
    @Published private(set) var phase = IslandPhase.resting
    @Published var isOpen = false
    @Published var level: CGFloat = 0
    @Published var transcript = ""
    @Published var reply = ""
    @Published var message = ""
    /// A small secondary line, such as a note that the voice fell back to the Mac voice.
    @Published var notice = ""
    /// What Jarvis is doing or just did on the Mac, such as "Opened ChatGPT".
    @Published var activity = ""
    /// Which step of a job is running, shown while Jarvis looks at the screen.
    @Published var progress = ""
    /// What Jarvis wants to do, read from the Mac rather than taken from the model.
    @Published var confirmTitle = ""
    @Published var confirmDetail = ""
    /// What Jarvis noticed on screen and is offering to help with.
    @Published var offerTitle = ""
    /// Stays on show for the whole recording, including when the island is otherwise hidden.
    @Published var isRecordingMeeting = false
    @Published var guideStep = 0
    @Published var guideLabel = ""
    @Published var conversation: [ChatTurn] = []
    @Published var hotkeySymbols = "⌃⌥"

    // Display geometry, set by the window controller.
    @Published var hasHardwareNotch = false
    @Published var notchWidth: CGFloat = 0
    @Published var topHeight: CGFloat = 24
    /// The island's current size, reported by the view for hit testing.
    var size: CGSize = .zero

    var onAsk: (String) -> Void = { _ in }
    var onStop: () -> Void = {}
    var onConfirm: (Bool) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}
    var onAcceptOffer: () -> Void = {}
    var onDismissOffer: () -> Void = {}

    private var restTask: Task<Void, Never>?

    func show(_ phase: IslandPhase) {
        restTask?.cancel()
        restTask = nil
        self.phase = phase
    }

    func rest() {
        show(.resting)
        level = 0
        transcript = ""
        reply = ""
        message = ""
        notice = ""
        activity = ""
        progress = ""
        confirmTitle = ""
        confirmDetail = ""
        offerTitle = ""
    }

    /// Keeps what's on the island readable for a moment, then folds it away.
    func rest(after seconds: Double) {
        restTask?.cancel()
        restTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.rest()
        }
    }

    func showMessage(_ text: String, lasting seconds: Double = 7) {
        message = text
        show(.message)
        rest(after: seconds)
    }
}
