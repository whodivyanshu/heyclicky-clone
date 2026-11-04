import Foundation

/// Gemini text-to-speech through the Interactions API.
public enum GeminiVoiceWire {
    public static let endpoint = "https://generativelanguage.googleapis.com/v1beta/interactions"
    public static let defaultModel = "gemini-3.8-flash-lite-tts"
    public static let defaultVoice = "Achird"
    public static let sampleRate: Double = 24000
    public static let defaultStyle = "natural, warm and conversational, like a helpful friend"
    /// A starting point for the Hindi assistant preset. It can still be changed in Settings.
    public static let hindiAssistantVoice = "Charon"
    public static let hindiAssistantStyle = "a deep, calm, composed and refined Hindi-speaking AI assistant, measured and precise"

    /// Gemini's prebuilt voices and the style Google describes for each.
    public static let voices: [(name: String, style: String)] = [
        ("Achird", "Friendly"), ("Sulafat", "Warm"), ("Zubenelgenubi", "Casual"), ("Vindemiatrix", "Gentle"),
        ("Achernar", "Soft"), ("Aoede", "Breezy"), ("Callirrhoe", "Easy-going"), ("Umbriel", "Easy-going"),
        ("Algieba", "Smooth"), ("Despina", "Smooth"), ("Zephyr", "Bright"), ("Autonoe", "Bright"),
        ("Puck", "Upbeat"), ("Laomedeia", "Upbeat"), ("Sadachbia", "Lively"), ("Fenrir", "Excitable"),
        ("Leda", "Youthful"), ("Iapetus", "Clear"), ("Erinome", "Clear"), ("Schedar", "Even"),
        ("Charon", "Informative"), ("Rasalgethi", "Informative"), ("Sadaltager", "Knowledgeable"),
        ("Kore", "Firm"), ("Orus", "Firm"), ("Alnilam", "Firm"), ("Pulcherrima", "Forward"),
        ("Gacrux", "Mature"), ("Enceladus", "Breathy"), ("Algenib", "Gravelly"),
    ]

    public static func requestBody(text: String, voice: String, model: String, style: String = defaultStyle) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": true,
            "input": [[
                "type": "user_input",
                "content": [[
                    "type": "text",
                    "text": text,
                    "annotations": [["type": "speech_metadata", "style": style]],
                ]],
            ]],
            "response_format": ["type": "audio"],
            "generation_config": ["speech_config": [["voice": voice]]],
        ] as [String: Any])
    }

    /// Raw audio from one server-sent-events line, or nil if it carries none.
    /// Streams are 16-bit signed little-endian PCM, mono, at `sampleRate`.
    public static func audio(fromSSELine line: String) throws -> Data? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            return nil
        }
        if let message = GeminiWire.errorMessage(in: object) {
            throw AIError("Gemini voice: \(message)")
        }
        guard let delta = object["delta"] as? [String: Any],
              delta["type"] as? String == "audio",
              let encoded = delta["data"] as? String
        else { return nil }
        return Data(base64Encoded: encoded)
    }
}
