import AVFoundation
import Speech

/// A long-running speech recognizer that never sends audio off this Mac.
/// It starts a new session every so often, because recognition sessions don't last forever.
@MainActor
final class OnDeviceRecognition {
    enum Source { case microphone, external }

    /// All the text of the current session so far.
    var onText: (String) -> Void = { _ in }
    /// A session has ended, with its final text.
    var onSessionEnd: (String) -> Void = { _ in }
    /// Return false to put off starting a new session, such as partway through someone's sentence.
    var canRenew: () -> Bool = { true }

    private static let sessionLength: UInt64 = 50_000_000_000

    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: SFSpeechAudioBufferRecognitionRequest?
        var request: SFSpeechAudioBufferRecognitionRequest? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private let source: Source
    private let box = RequestBox()
    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private var task: SFSpeechRecognitionTask?
    private var renewal: Task<Void, Never>?
    private var latest = ""
    /// Goes up with every session, so late results from an old one are ignored.
    private var generation = 0
    private(set) var isRunning = false

    init(source: Source = .microphone) {
        self.source = source
    }

    /// Whether this language can be recognized without sending audio anywhere.
    static func isSupported(locale: Locale?) -> Bool {
        let recognizer = locale.map { SFSpeechRecognizer(locale: $0) } ?? SFSpeechRecognizer()
        return recognizer?.supportsOnDeviceRecognition == true
    }

    func start(locale: Locale?) throws {
        guard !isRunning else { return }
        guard let recognizer = locale.map({ SFSpeechRecognizer(locale: $0) }) ?? SFSpeechRecognizer(),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition
        else { throw JarvisMessage("This needs on-device speech recognition, which isn't available for this language on this Mac.") }
        self.recognizer = recognizer

        if source == .microphone {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw JarvisMessage("No microphone found.") }
            input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.makeTap(box))
            engine.prepare()
            try engine.start()
            self.engine = engine
        }
        isRunning = true
        beginSession()
    }

    /// `flush` hands over what the current session has heard, for callers that keep it.
    func stop(flush: Bool = false) {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        renewal?.cancel()
        renewal = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        box.request?.endAudio()
        box.request = nil
        task?.cancel()
        task = nil
        let last = latest
        latest = ""
        if flush { onSessionEnd(last) }
    }

    /// For audio that doesn't come from the microphone. Safe to call from any thread.
    nonisolated func append(_ buffer: CMSampleBuffer) {
        box.request?.appendAudioSampleBuffer(buffer)
    }

    private func beginSession() {
        guard isRunning, let recognizer else { return }
        generation += 1
        let session = generation
        latest = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        box.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.makeResultHandler { text, ended in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in self?.handle(session: session, text: text, ended: ended) }
            }
        })
        scheduleRenewal()
    }

    private func scheduleRenewal() {
        renewal?.cancel()
        renewal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.sessionLength)
            guard !Task.isCancelled else { return }
            self?.renew()
        }
    }

    private func renew() {
        guard isRunning else { return }
        guard canRenew() else {
            scheduleRenewal()
            return
        }
        let last = latest
        generation += 1
        box.request?.endAudio()
        task?.cancel()
        onSessionEnd(last)
        beginSession()
    }

    private func handle(session: Int, text: String?, ended: Bool) {
        guard session == generation, isRunning else { return }
        if let text {
            latest = text
            onText(text)
        }
        guard ended else { return }
        // Long silence ends a session too, so starting again is routine. The pause stops a repeating error from spinning.
        let last = latest
        generation += 1
        task = nil
        onSessionEnd(last)
        latest = ""
        renewal?.cancel()
        renewal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.beginSession()
        }
    }

    // These run on background audio and recognizer queues, so they must stay outside the main actor.
    private nonisolated static func makeTap(_ box: RequestBox) -> AVAudioNodeTapBlock {
        { buffer, _ in box.request?.append(buffer) }
    }

    private nonisolated static func makeResultHandler(
        _ handler: @escaping @Sendable (String?, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            handler(result?.bestTranscription.formattedString, (result?.isFinal ?? false) || error != nil)
        }
    }
}
