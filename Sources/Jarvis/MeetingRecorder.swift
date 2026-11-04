import CoreMedia
import JarvisCore
import ScreenCaptureKit

/// Turns your microphone and the Mac's sound into a transcript, on this Mac. The audio itself is never saved.
@MainActor
final class MeetingRecorder {
    var onLine: (MeetingLine) -> Void = { _ in }

    private let microphone = OnDeviceRecognition()
    private let systemAudio = OnDeviceRecognition(source: .external)
    private var stream: SCStream?
    private var output: AudioOutput?
    private(set) var isRecording = false

    private final class AudioOutput: NSObject, SCStreamOutput {
        let recognition: OnDeviceRecognition
        init(recognition: OnDeviceRecognition) { self.recognition = recognition }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .audio, sampleBuffer.isValid else { return }
            recognition.append(sampleBuffer)
        }
    }

    func start(locale: Locale?) async throws {
        guard !isRecording else { return }
        microphone.onSessionEnd = { [weak self] in self?.commit($0, speaker: "Me") }
        systemAudio.onSessionEnd = { [weak self] in self?.commit($0, speaker: "Others") }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw JarvisMessage("Couldn't reach the Mac's sound.") }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16000
        configuration.channelCount = 1
        // Screen capture always comes with video, so this keeps it as small and slow as it goes.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        try systemAudio.start(locale: locale)
        do {
            try microphone.start(locale: locale)
            let output = AudioOutput(recognition: systemAudio)
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: nil)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "local.jarvis.meeting-audio"))
            try await stream.startCapture()
            self.stream = stream
            self.output = output
            isRecording = true
        } catch {
            microphone.stop()
            systemAudio.stop()
            throw error
        }
    }

    func stop() async {
        guard isRecording else { return }
        isRecording = false
        try? await stream?.stopCapture()
        stream = nil
        output = nil
        microphone.stop(flush: true)
        systemAudio.stop(flush: true)
    }

    private func commit(_ text: String, speaker: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onLine(MeetingLine(speaker: speaker, text: trimmed, date: Date()))
    }
}
