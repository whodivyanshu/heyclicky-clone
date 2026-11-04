import AVFoundation
import JarvisCore

enum VoiceConfig {
    case system(identifier: String)
    case gemini(apiKey: String, voice: String, model: String, fallbackIdentifier: String)
}

/// One Gemini speech request. It starts downloading immediately, so its audio is ready sooner when its turn comes.
final class GeminiVoiceStream: Sendable {
    let chunks: AsyncThrowingStream<Data, Error>
    private let task: Task<Void, Never>

    init(text: String, apiKey: String, voice: String, model: String) {
        let (chunks, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        self.chunks = chunks
        task = Task.detached {
            do {
                try await Self.download(text: text, apiKey: apiKey, voice: voice, model: model) { continuation.yield($0) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func cancel() {
        task.cancel()
    }

    private static func download(text: String, apiKey: String, voice: String, model: String, onChunk: (Data) -> Void) async throws {
        var request = URLRequest(url: URL(string: GeminiVoiceWire.endpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try GeminiVoiceWire.requestBody(text: text, voice: voice, model: model)

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

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
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
    var onDrained: () -> Void = {}
    var onVoiceError: (String) -> Void = { _ in }
    var voiceConfig: () -> VoiceConfig = { .system(identifier: "") }

    private enum Item {
        case point(PointTag)
        case target(PointTag)
        case action(ActionTag)
        case say(String, voice: GeminiVoiceStream?)
    }

    /// Keeps each Gemini request a reasonable size while still sending fewer requests than one per sentence.
    private static let maxMergedCharacters = 400

    private let synthesizer = AVSpeechSynthesizer()
    private var player: PCMStreamPlayer?
    private var currentVoice: GeminiVoiceStream?
    private var config = VoiceConfig.system(identifier: "")
    private var queue: [Item] = []
    private var unsentText = ""
    private var isSpeaking = false
    private var inputComplete = false
    private var geminiFailedThisTurn = false
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
        dropsFurtherSpeech = false
    }

    func enqueue(_ beats: [Beat]) {
        for beat in beats {
            switch beat {
            case .say(let text):
                if dropsFurtherSpeech { continue }
                if case .gemini = config {
                    unsentText += unsentText.isEmpty ? text : " " + text
                    if unsentText.count >= Self.maxMergedCharacters { flushUnsentText() }
                } else {
                    queue.append(.say(text, voice: nil))
                }
            case .point(let tag):
                flushUnsentText()
                queue.append(.point(tag))
            case .target(let tag):
                flushUnsentText()
                queue.append(.target(tag))
            case .action(let tag):
                flushUnsentText()
                queue.append(.action(tag))
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
    }

    private func flushUnsentText() {
        guard !unsentText.isEmpty else { return }
        let text = unsentText
        unsentText = ""
        var stream: GeminiVoiceStream?
        if case .gemini(let key, let voice, let model, _) = config, !geminiFailedThisTurn {
            stream = GeminiVoiceStream(text: text, apiKey: key, voice: voice, model: model)
        }
        queue.append(.say(text, voice: stream))
    }

    private func advance() {
        while !isSpeaking, !queue.isEmpty {
            switch queue.removeFirst() {
            case .point(let tag):
                onPoint(tag)
            case .target(let tag):
                onTarget(tag)
            case .action(let tag):
                isSpeaking = true
                perform(tag)
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
    private func perform(_ tag: ActionTag) {
        let started = generation
        Task {
            let failure = await onAction(tag)
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
        if case .gemini(let key, let voice, let model, _) = config, !geminiFailedThisTurn {
            queue.insert(.say(text, voice: GeminiVoiceStream(text: text, apiKey: key, voice: voice, model: model)), at: 0)
        } else {
            queue.insert(.say(text, voice: nil), at: 0)
        }
    }

    private func play(_ voice: GeminiVoiceStream, text: String) {
        currentVoice = voice
        let started = generation
        let player = PCMStreamPlayer()
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
                if !heardAny { throw AIError("Gemini voice: the response had no audio.") }
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
        let identifier: String
        switch config {
        case .system(let chosen): identifier = chosen
        case .gemini(_, _, _, let fallback): identifier = fallback
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.macVoice(identifier: identifier)
        synthesizer.speak(utterance)
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
