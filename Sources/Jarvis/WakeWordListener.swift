import Foundation
import JarvisCore

/// Listens for "hey Jarvis" on this Mac, so no audio leaves it while it waits.
@MainActor
final class WakeWordListener {
    /// The wake phrase was heard, and the words after it are being collected.
    var onWake: () -> Void = {}
    var onPartial: (String) -> Void = { _ in }
    /// The finished request, which is empty if they stopped after "hey Jarvis".
    var onCommand: (String) -> Void = { _ in }

    private static let silenceAfterCommand: TimeInterval = 1.2
    private static let waitForCommand: TimeInterval = 5
    private static let longestCommand: TimeInterval = 30

    private let recognition = OnDeviceRecognition()
    private var capture: Task<Void, Never>?
    private var command: String?
    private var lastChange = Date()
    private var wokeAt = Date()

    init() {
        recognition.onText = { [weak self] in self?.heard($0) }
        recognition.onSessionEnd = { [weak self] _ in
            if self?.command != nil { self?.finish() }
        }
        // Never cut someone off partway through a request.
        recognition.canRenew = { [weak self] in self?.command == nil }
    }

    static func isSupported(locale: Locale?) -> Bool {
        OnDeviceRecognition.isSupported(locale: locale)
    }

    func start(locale: Locale?) throws {
        try recognition.start(locale: locale)
    }

    func stop() {
        capture?.cancel()
        capture = nil
        command = nil
        recognition.stop()
    }

    private func heard(_ text: String) {
        guard let words = WakeWord.command(in: text) else { return }
        if command == nil {
            wokeAt = Date()
            lastChange = wokeAt
            command = words
            onWake()
            watchForEnd()
        } else if words != command {
            command = words
            lastChange = Date()
        }
        onPartial(words)
    }

    private func watchForEnd() {
        capture?.cancel()
        capture = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self, !Task.isCancelled, let command = self.command else { return }
                let now = Date()
                let waited = now.timeIntervalSince(self.lastChange)
                let isDone = command.isEmpty ? waited >= Self.waitForCommand : waited >= Self.silenceAfterCommand
                if isDone || now.timeIntervalSince(self.wokeAt) >= Self.longestCommand {
                    self.finish()
                    return
                }
            }
        }
    }

    private func finish() {
        let heard = command ?? ""
        stop()
        onCommand(heard)
    }
}

/// Listens while Jarvis is talking, to notice them talking over it. Everything stays on this Mac.
@MainActor
final class BargeInListener {
    /// What Jarvis has said so far in this reply, to tell its voice apart from theirs.
    var speaking: () -> String = { "" }
    var onStop: () -> Void = {}
    /// They've started talking. Whatever Jarvis was doing should stop now.
    var onInterrupt: () -> Void = {}
    var onPartial: (String) -> Void = { _ in }
    var onCommand: (String) -> Void = { _ in }

    private static let silenceAfterCommand: TimeInterval = 1.1
    private static let longestCommand: TimeInterval = 30

    private let recognition = OnDeviceRecognition()
    private var startIndex: Int?
    private var heardText = ""
    private var lastChange = Date()
    private var capture: Task<Void, Never>?

    init() {
        recognition.onText = { [weak self] in self?.heard($0) }
        recognition.onSessionEnd = { [weak self] _ in
            if self?.startIndex != nil { self?.finish() }
        }
        recognition.canRenew = { [weak self] in self?.startIndex == nil }
    }

    func start(locale: Locale?) throws {
        try recognition.start(locale: locale)
    }

    func stop() {
        capture?.cancel()
        capture = nil
        startIndex = nil
        heardText = ""
        recognition.stop()
    }

    private func heard(_ text: String) {
        if let startIndex {
            if text != heardText {
                heardText = text
                lastChange = Date()
                onPartial(BargeInRules.request(heard: text, startingAt: startIndex))
            }
            return
        }
        switch BargeInRules.interruption(heard: text, speaking: speaking()) {
        case .stop:
            stop()
            onStop()
        case .request(let index):
            startIndex = index
            heardText = text
            lastChange = Date()
            onInterrupt()
            onPartial(BargeInRules.request(heard: text, startingAt: index))
            watchForEnd()
        case nil:
            break
        }
    }

    private func watchForEnd() {
        let started = Date()
        capture?.cancel()
        capture = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self, !Task.isCancelled else { return }
                let now = Date()
                if now.timeIntervalSince(self.lastChange) >= Self.silenceAfterCommand || now.timeIntervalSince(started) >= Self.longestCommand {
                    self.finish()
                    return
                }
            }
        }
    }

    private func finish() {
        let command = startIndex.map { BargeInRules.request(heard: heardText, startingAt: $0) } ?? ""
        stop()
        onCommand(command)
    }
}
