import AVFoundation
import JarvisCore

enum VoiceConfig {
    case system(identifier: String)
    case gemini(apiKey: String, voice: String, model: String, style: String, assistantEffect: Bool, fallbackIdentifier: String)
    case kokoro(englishVoice: Int, hindiVoice: Int, assistantEffect: Bool, fallbackIdentifier: String)

    var assistantEffect: Bool {
        switch self {
        case .system: false
        case .gemini(_, _, _, _, let effect, _), .kokoro(_, _, let effect, _): effect
        }
    }

    var fallbackIdentifier: String {
        switch self {
        case .system(let identifier): identifier
        case .gemini(_, _, _, _, _, let fallback), .kokoro(_, _, _, let fallback): fallback
        }
    }

    /// Voices that make audio as a stream, as opposed to the Mac's own speech.
    var usesAudioStream: Bool {
        if case .system = self { return false }
        return true
    }
}

/// One piece of speech. It starts being made immediately, so its audio is ready sooner when its turn comes.
final class VoiceStream: Sendable {
    let chunks: AsyncThrowingStream<Data, Error>
    private let task: Task<Void, Never>

    init(text: String, apiKey: String, voice: String, model: String, style: String) {
        let (chunks, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        self.chunks = chunks
        task = Task.detached {
            do {
                try await Self.download(text: text, apiKey: apiKey, voice: voice, model: model, style: style) { continuation.yield($0) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// Kokoro makes each piece on this Mac, in the same audio format as Gemini.
    init(text: String, kokoroVoice: Int) {
        let (chunks, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        self.chunks = chunks
        task = Task.detached {
            do {
                try Task.checkCancellation()
                continuation.yield(try await KokoroEngine.shared.speak(text, voice: kokoroVoice))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func cancel() {
        task.cancel()
    }

    private static func download(text: String, apiKey: String, voice: String, model: String, style: String, onChunk: (Data) -> Void) async throws {
        var request = URLRequest(url: URL(string: GeminiVoiceWire.endpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try GeminiVoiceWire.requestBody(text: text, voice: voice, model: model, style: style)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw AIError("Gemini voice: " + (GeminiWire.errorMessage(fromBody: body) ?? "HTTP \(status)"))
        }
        for try await line in bytes.lines {
            if let audio = try GeminiVoiceWire.audio(fromSSELine: line) { onChunk(audio) }
        }
    }
}

/// Plays streamed 16-bit PCM as it arrives.
@MainActor
final class PCMStreamPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: GeminiVoiceWire.sampleRate, channels: 1)!
    private var leftoverByte: UInt8?
    private var pendingBuffers = 0
    private var inputEnded = false
    private var onFinished: (() -> Void)?

    /// `assistantEffect` adds a little low-end weight and a faint room, for a more synthetic assistant sound.
    init(assistantEffect: Bool = false) {
        engine.attach(node)
        guard assistantEffect else {
            engine.connect(node, to: engine.mainMixerNode, format: format)
            return
        }
        let equalizer = AVAudioUnitEQ(numberOfBands: 2)
        let depth = equalizer.bands[0]
        depth.filterType = .lowShelf
        depth.frequency = 180
        depth.gain = 3
        depth.bypass = false
        let clarity = equalizer.bands[1]
        clarity.filterType = .highShelf
        clarity.frequency = 4500
        clarity.gain = 2
        clarity.bypass = false
        let room = AVAudioUnitReverb()
        room.loadFactoryPreset(.smallRoom)
        room.wetDryMix = 10
        // The speech is mono, but the effects need stereo, so a mixer converts it first.
        let toStereo = AVAudioMixerNode()
        let stereo = AVAudioFormat(standardFormatWithSampleRate: GeminiVoiceWire.sampleRate, channels: 2)!
        engine.attach(toStereo)
        engine.attach(equalizer)
        engine.attach(room)
        engine.connect(node, to: toStereo, format: format)
        engine.connect(toStereo, to: equalizer, format: stereo)
        engine.connect(equalizer, to: room, format: stereo)
        engine.connect(room, to: engine.mainMixerNode, format: stereo)
    }

    func append(_ data: Data) throws {
        if !engine.isRunning {
            try engine.start()
            node.play()
        }
        var bytes = [UInt8](data)
        // A sample can be split between two network chunks.
        if let leftoverByte { bytes.insert(leftoverByte, at: 0) }
        leftoverByte = bytes.count % 2 == 1 ? bytes.removeLast() : nil

        let frames = bytes.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames {
            let value = Int16(bitPattern: UInt16(bytes[frame * 2]) | UInt16(bytes[frame * 2 + 1]) << 8)
            samples[frame] = Float(value) / 32768
        }

        pendingBuffers += 1
        let played = Self.makeCompletion { [weak self] in
            Task { @MainActor in self?.bufferPlayed() }
        }
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: played)
    }

    /// Runs on an audio thread, so it must stay outside the main actor.
    private nonisolated static func makeCompletion(_ done: @escaping @Sendable () -> Void) -> AVAudioPlayerNodeCompletionHandler {
        { _ in done() }
    }

    /// Calls `done` after everything appended so far has been heard.
    func finish(_ done: @escaping () -> Void) {
        onFinished = done
        inputEnded = true
        completeIfDone()
    }

    func stop() {
        onFinished = nil
        node.stop()
        engine.stop()
    }

    private func bufferPlayed() {
        pendingBuffers -= 1
        completeIfDone()
    }

    private func completeIfDone() {
        guard inputEnded, pendingBuffers <= 0, let done = onFinished else { return }
        onFinished = nil
        node.stop()
        engine.stop()
        done()
    }
}

/// Plays beats in order: pointing runs when reached, and speech waits for the speech before it.
/// If a Gemini voice request fails before any sound, that text uses the Mac voice instead.
@MainActor
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    var onPoint: (PointTag) -> Void = { _ in }
    var onTarget: (PointTag) -> Void = { _ in }
    /// Runs an action and returns what to say instead of the model's reply if it failed.
    var onAction: (ActionTag) async -> String? = { _ in nil }
    /// Same as `onAction`, for a click. It watches for task cancellation, because stopping must also stop a pending click.
    var onClick: (PointTag) async -> String? = { _ in nil }
    var onDrained: () -> Void = {}
    var onVoiceError: (String) -> Void = { _ in }
    var voiceConfig: () -> VoiceConfig = { .system(identifier: "") }

    private enum Item {
        case point(PointTag)
        case target(PointTag)
        case click(PointTag)
        case action(ActionTag)
        case say(String, voice: VoiceStream?)
    }

    /// Keeps each Gemini request a reasonable size while still sending fewer requests than one per sentence.
    private static let maxMergedCharacters = 400

    private let synthesizer = AVSpeechSynthesizer()
    /// Speaks while the queue is held waiting for a confirmation, so it has no delegate to move the queue along.
    private let announcer = AVSpeechSynthesizer()
    private var announcementPlayer: PCMStreamPlayer?
    private var announcementVoice: VoiceStream?
    private var announcementGeneration = 0
    private var player: PCMStreamPlayer?
    private var currentVoice: VoiceStream?
    private var runningAction: Task<Void, Never>?
    private var config = VoiceConfig.system(identifier: "")
    private var queue: [Item] = []
    private var unsentText = ""
    private var isSpeaking = false
    private var inputComplete = false
    private var geminiFailedThisTurn = false
    private var sentFirstSentence = false
    /// After a failed action the model's "Opening it now" would be wrong, so the rest of its reply is dropped.
    private var dropsFurtherSpeech = false
    /// Goes up on every stop, so audio that arrives late can't start playing.
    private var generation = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func begin() {
        stop()
        config = voiceConfig()
        geminiFailedThisTurn = false
        sentFirstSentence = false
        dropsFurtherSpeech = false
    }

    func enqueue(_ beats: [Beat]) {
        for beat in beats {
            switch beat {
            case .say(let text):
                if dropsFurtherSpeech { continue }
                if config.usesAudioStream {
                    unsentText += unsentText.isEmpty ? text : " " + text
                    // The first sentence goes straight away, so the voice can start before the model has finished writing.
                    if !sentFirstSentence || unsentText.count >= Self.maxMergedCharacters {
                        sentFirstSentence = true
                        flushUnsentText()
                    }
                } else {
                    queue.append(.say(text, voice: nil))
                }
            case .point(let tag):
                flushUnsentText()
                queue.append(.point(tag))
            case .target(let tag):
                flushUnsentText()
                queue.append(.target(tag))
            case .click(let tag):
                flushUnsentText()
                queue.append(.click(tag))
            case .action(let tag):
                flushUnsentText()
                queue.append(.action(tag))
            case .next, .done:
                // The coordinator acts on these once everything in the queue has finished.
                break
            }
        }
        advance()
    }

    func finishInput() {
        flushUnsentText()
        inputComplete = true
        advance()
    }

    func stop() {
        generation += 1
        runningAction?.cancel()
        runningAction = nil
        for item in queue {
            if case .say(_, let voice) = item { voice?.cancel() }
        }
        queue.removeAll()
        unsentText = ""
        currentVoice?.cancel()
        currentVoice = nil
        player?.stop()
        player = nil
        isSpeaking = false
        inputComplete = false
        synthesizer.stopSpeaking(at: .immediate)
        stopAnnouncement()
    }

    /// Says something right away, outside the queue, which stays held.
    func announce(_ text: String) {
        stopAnnouncement()
        guard let voice = voiceStream(for: text) else {
            announcer.speak(macUtterance(text))
            return
        }
        let player = PCMStreamPlayer(assistantEffect: config.assistantEffect)
        announcementVoice = voice
        announcementPlayer = player
        let started = announcementGeneration
        Task {
            var heardAny = false
            do {
                for try await chunk in voice.chunks {
                    guard started == announcementGeneration else { return }
                    try player.append(chunk)
                    heardAny = true
                }
                player.finish {}
            } catch {
                guard started == announcementGeneration, !heardAny else { return }
                announcer.speak(macUtterance(text))
            }
        }
    }

    func stopAnnouncement() {
        announcementGeneration += 1
        announcementVoice?.cancel()
        announcementVoice = nil
        announcementPlayer?.stop()
        announcementPlayer = nil
        announcer.stopSpeaking(at: .immediate)
    }

    private func flushUnsentText() {
        guard !unsentText.isEmpty else { return }
        let text = unsentText
        unsentText = ""
        queue.append(.say(text, voice: voiceStream(for: text)))
    }

    private func voiceStream(for text: String) -> VoiceStream? {
        guard !geminiFailedThisTurn else { return nil }
        switch config {
        case .gemini(let key, let voice, let model, let style, _, _):
            return VoiceStream(text: text, apiKey: key, voice: voice, model: model, style: style)
        case .kokoro(let english, let hindi, _, _):
            return VoiceStream(text: text, kokoroVoice: KokoroCatalog.voice(for: text, english: english, hindi: hindi))
        case .system:
            return nil
        }
    }

    private func advance() {
        while !isSpeaking, !queue.isEmpty {
            switch queue.removeFirst() {
            case .point(let tag):
                onPoint(tag)
            case .target(let tag):
                onTarget(tag)
            case .click(let tag):
                isSpeaking = true
                perform { [onClick] in await onClick(tag) }
            case .action(let tag):
                isSpeaking = true
                perform { [onAction] in await onAction(tag) }
            case .say(let text, let voice):
                isSpeaking = true
                if let voice {
                    play(voice, text: text)
                } else {
                    speakWithMacVoice(text)
                }
            }
        }
        if !isSpeaking, queue.isEmpty, inputComplete {
            inputComplete = false
            onDrained()
        }
    }

    /// Holds the queue until the action finishes, so speech never gets ahead of what really happened.
    private func perform(_ work: @escaping () async -> String?) {
        let started = generation
        runningAction = Task {
            let failure = await work()
            guard started == generation else { return }
            if let failure { replaceRemainingSpeech(with: failure) }
            isSpeaking = false
            advance()
        }
    }

    private func replaceRemainingSpeech(with text: String) {
        for item in queue {
            if case .say(_, let voice) = item { voice?.cancel() }
        }
        queue.removeAll { if case .say = $0 { return true } else { return false } }
        unsentText = ""
        dropsFurtherSpeech = true
        // Empty means the reply was dropped without a word, because Jarvis is about to try another way.
        guard !text.isEmpty else { return }
        queue.insert(.say(text, voice: voiceStream(for: text)), at: 0)
    }

    private func play(_ voice: VoiceStream, text: String) {
        currentVoice = voice
        let started = generation
        let player = PCMStreamPlayer(assistantEffect: config.assistantEffect)
        self.player = player
        Task {
            var heardAny = false
            do {
                for try await chunk in voice.chunks {
                    guard started == generation else { return }
                    try player.append(chunk)
                    heardAny = true
                }
                guard started == generation else { return }
                if !heardAny { throw AIError("The voice had no audio.") }
            } catch {
                guard started == generation else { return }
                if !geminiFailedThisTurn {
                    geminiFailedThisTurn = true
                    onVoiceError("Using the Mac voice. \(error.localizedDescription)")
                }
                if !heardAny {
                    self.player = nil
                    speakWithMacVoice(text)
                    return
                }
                // Part of it played, and repeating it from the start would be worse than stopping there.
            }
            player.finish { [weak self] in
                guard let self, started == self.generation else { return }
                self.finishedSpeaking()
            }
        }
    }

    private func speakWithMacVoice(_ text: String) {
        synthesizer.speak(macUtterance(text))
    }

    private func macUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.macVoice(identifier: config.fallbackIdentifier)
        return utterance
    }

    private func finishedSpeaking() {
        isSpeaking = false
        player = nil
        currentVoice = nil
        advance()
    }

    private static func macVoice(identifier: String) -> AVSpeechSynthesisVoice? {
        if !identifier.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: identifier) {
            return chosen
        }
        return bestVoices().first ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    /// Voices in the user's language, highest quality first.
    static func bestVoices() -> [AVSpeechSynthesisVoice] {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = language.split(separator: "-").first.map(String.init) ?? language
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted {
                if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
                return ($0.language == language ? 0 : 1) < ($1.language == language ? 0 : 1)
            }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedSpeaking() }
    }
}
