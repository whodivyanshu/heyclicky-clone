import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import JarvisCore
import Security

enum AppleModelLocation: String, CaseIterable, Identifiable {
    case onDevice, privateCloud
    var id: String { rawValue }
    var title: String { self == .onDevice ? "This Mac" : "Private Cloud Compute" }
}

/// Apple's system models, through the Foundation Models framework. Needs macOS 27 for screenshots.
struct AppleIntelligenceProvider: AIProvider {
    let location: AppleModelLocation
    /// The language replies must be in, when it isn't the system's own.
    let locale: Locale?

    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.friendly(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Why this model can't be used right now, or nil when it's ready.
    static func unavailableReason(_ location: AppleModelLocation) -> String? {
        guard #available(macOS 27, *) else { return "Apple Intelligence needs macOS 27 or later in Jarvis." }
        switch location {
        case .onDevice:
            guard case .unavailable(let reason) = SystemLanguageModel.default.availability else { return nil }
            switch reason {
            case .deviceNotEligible: return "This Mac can't run Apple Intelligence."
            case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings."
            case .modelNotReady: return "The model isn't ready yet. It may still be downloading."
            @unknown default: return "The on-device model isn't available."
            }
        case .privateCloud:
            // Without this entitlement the framework stops the whole app with a fatal error, so check first.
            guard hasPrivateCloudEntitlement else {
                return "This build of Jarvis isn't approved for Private Cloud Compute. Apple grants that per developer account."
            }
            guard case .unavailable(let reason) = PrivateCloudComputeLanguageModel().availability else { return nil }
            switch reason {
            case .deviceNotEligible: return "This Mac can't use Private Cloud Compute."
            case .systemNotReady: return "Private Cloud Compute isn't ready yet. Check that Apple Intelligence is on."
            @unknown default: return "Private Cloud Compute isn't available."
            }
        }
    }

    private static var hasPrivateCloudEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.private-cloud-compute" as CFString, nil) != nil
    }

    private func run(_ request: AIRequest, _ continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        if let reason = Self.unavailableReason(location) { throw AIError(reason) }
        guard #available(macOS 27, *) else { return }

        switch location {
        case .onDevice:
            let model = SystemLanguageModel.default
            if let locale, !model.supportsLocale(locale) { throw Self.unsupportedLanguage }
            try await respond(with: model, request, continuation)
        case .privateCloud:
            let model = PrivateCloudComputeLanguageModel()
            if let locale, try await !model.supportsLocale(locale) { throw Self.unsupportedLanguage }
            try await respond(with: model, request, continuation)
        }
    }

    @available(macOS 27, *)
    private func respond(with model: some LanguageModel, _ request: AIRequest, _ continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let session = LanguageModelSession(model: model, instructions: request.system)
        let images = try request.jpegImages.map { Attachment(try Self.cgImage(fromJPEG: $0)) }
        let prompt = Prompt {
            images
            request.textWithHistory
        }

        // Each snapshot holds the whole reply so far, but callers expect only the new text.
        // Counted in scalars so a character still being built can't be skipped.
        var sent = 0
        for try await snapshot in session.streamResponse(to: prompt) {
            let scalars = snapshot.content.unicodeScalars
            guard scalars.count > sent else { continue }
            continuation.yield(String(String.UnicodeScalarView(scalars.dropFirst(sent))))
            sent = scalars.count
        }
    }

    private static func cgImage(fromJPEG data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw AIError("Couldn't read the screenshot.") }
        return image
    }

    private static let unsupportedLanguage = AIError("This Apple Intelligence model doesn't support Hindi. Turn off Hindi assistant or choose another AI in Settings.")

    private static func friendly(_ error: Error) -> Error {
        if error is AIError { return error }
        guard #available(macOS 27, *) else { return error }
        switch error {
        case LanguageModelError.contextSizeExceeded, LanguageModelSession.GenerationError.exceededContextWindowSize:
            return AIError("Too much for this Apple Intelligence model to read at once: the instructions, screenshots and conversation don't fit.")
        case LanguageModelError.guardrailViolation, LanguageModelSession.GenerationError.guardrailViolation:
            return AIError("Apple Intelligence's safety filter blocked this request.")
        default:
            return AIError("Apple Intelligence: \(error.localizedDescription)")
        }
    }
}
