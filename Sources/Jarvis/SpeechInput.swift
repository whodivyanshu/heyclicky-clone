import AVFoundation
import Foundation
import Speech

/// Live transcription from the microphone with Apple's speech recognizer.
@MainActor
final class SpeechInput {
    var onPartial: (String) -> Void = { _ in }
    var onLevel: (Float) -> Void = { _ in }

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    private var finishWaiter: CheckedContinuation<Void, Never>?
    private var failure: Error?

    func start() throws {
        cancel()
        transcript = ""
        failure = nil

        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw JarvisMessage("Speech recognition isn't available right now.")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        // A new engine each time picks up microphone changes such as AirPods connecting.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw JarvisMessage("No microphone found.")
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(request: request) { [weak self] level in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onLevel(level) } }
        })
        engine.prepare()
        try engine.start()

        self.engine = engine
        self.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.makeResultHandler { [weak self] text, isFinal, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(text: text, isFinal: isFinal, error: error) }
            }
        })
    }

    /// Stops listening and returns the final transcript, waiting briefly for the recognizer to settle.
    func stop() async throws -> String {
        guard engine != nil else { return transcript }
        stopAudio()
        request?.endAudio()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finishWaiter = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.resumeWaiter() }
            }
        }
        task?.cancel()
        task = nil
        request = nil

        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, let failure, !Self.isNoSpeech(failure) { throw failure }
        return text
    }

    func cancel() {
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        resumeWaiter()
    }

    private func stopAudio() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func handle(text: String?, isFinal: Bool, error: Error?) {
        if let text {
            transcript = text
            onPartial(text)
        }
        if let error { failure = error }
        if isFinal || error != nil { resumeWaiter() }
    }

    private func resumeWaiter() {
        finishWaiter?.resume()
        finishWaiter = nil
    }

    private static func isNoSpeech(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "kAFAssistantErrorDomain" && error.code == 1110
    }

    // These run on background audio and recognizer queues, so they must stay outside the main actor.
    private nonisolated static func makeTap(
        request: SFSpeechAudioBufferRecognitionRequest,
        level: @escaping @Sendable (Float) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for index in 0..<count { sum += samples[index] * samples[index] }
            level(min(1, (sum / Float(count)).squareRoot() * 12))
        }
    }

    private nonisolated static func makeResultHandler(
        _ handler: @escaping @Sendable (String?, Bool, Error?) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            handler(result?.bestTranscription.formattedString, result?.isFinal ?? false, error)
        }
    }
}
