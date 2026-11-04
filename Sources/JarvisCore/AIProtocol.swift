import Foundation

public struct ChatTurn: Equatable, Sendable {
    public var user: String
    public var assistant: String

    public init(user: String, assistant: String) {
        self.user = user
        self.assistant = assistant
    }
}

public struct AIRequest: Sendable {
    public var system: String
    public var history: [ChatTurn]
    public var userText: String
    public var jpegImages: [Data]

    public init(system: String, history: [ChatTurn] = [], userText: String, jpegImages: [Data] = []) {
        self.system = system
        self.history = history
        self.userText = userText
        self.jpegImages = jpegImages
    }

    /// The user's text with earlier turns in front, for providers that run a fresh session per request.
    public var textWithHistory: String {
        guard !history.isEmpty else { return userText }
        let earlier = history
            .map { "User: \($0.user)\nYou: \($0.assistant)" }
            .joined(separator: "\n")
        return "Earlier in this conversation:\n\(earlier)\n\nNow:\n\(userText)"
    }
}

public struct AIError: LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Gemini

public enum GeminiWire {
    public static func requestBody(_ request: AIRequest) throws -> Data {
        var contents: [[String: Any]] = []
        for turn in request.history {
            contents.append(["role": "user", "parts": [["text": turn.user]]])
            contents.append(["role": "model", "parts": [["text": turn.assistant]]])
        }
        var parts: [[String: Any]] = request.jpegImages.map {
            ["inlineData": ["mimeType": "image/jpeg", "data": $0.base64EncodedString()]]
        }
        parts.append(["text": request.userText])
        contents.append(["role": "user", "parts": parts])

        return try JSONSerialization.data(withJSONObject: [
            "systemInstruction": ["parts": [["text": request.system]]],
            "contents": contents,
        ])
    }

    /// Extracts answer text from one server-sent-events line, or nil if it has none.
    public static func text(fromSSELine line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let object = jsonObject(payload) else { return nil }
        if let message = errorMessage(in: object) { throw AIError(message) }

        let candidates = object["candidates"] as? [[String: Any]]
        let content = candidates?.first?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]] ?? []
        let text = parts
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
        return text.isEmpty ? nil : text
    }

    public static func errorMessage(in object: [String: Any]) -> String? {
        (object["error"] as? [String: Any])?["message"] as? String
    }

    public static func errorMessage(fromBody body: String) -> String? {
        if let object = jsonObject(body) { return errorMessage(in: object) }
        if let array = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]],
           let first = array.first {
            return errorMessage(in: first)
        }
        return nil
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }
}

// MARK: - Ollama

/// A model running on this Mac through Ollama, using its chat API.
public enum OllamaWire {
    public static let endpoint = "http://127.0.0.1:11434"

    public static func requestBody(_ request: AIRequest, model: String) throws -> Data {
        var messages: [[String: Any]] = [["role": "system", "content": request.system]]
        for turn in request.history {
            messages.append(["role": "user", "content": turn.user])
            messages.append(["role": "assistant", "content": turn.assistant])
        }
        var latest: [String: Any] = ["role": "user", "content": request.userText]
        if !request.jpegImages.isEmpty {
            latest["images"] = request.jpegImages.map { $0.base64EncodedString() }
        }
        messages.append(latest)
        return try JSONSerialization.data(withJSONObject: ["model": model, "stream": true, "messages": messages] as [String: Any])
    }

    /// Answer text from one line of the response, or nil if it has none.
    public static func text(fromLine line: String) throws -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        if let message = object["error"] as? String { throw AIError("Ollama: \(message)") }
        let text = (object["message"] as? [String: Any])?["content"] as? String
        return text?.isEmpty == false ? text : nil
    }

    public static func errorMessage(fromBody body: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["error"] as? String
    }

    /// The installed model names from `/api/tags`.
    public static func modelNames(fromTags data: Data) -> [String] {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = object?["models"] as? [[String: Any]] ?? []
        return models.compactMap { $0["name"] as? String }
    }
}

// MARK: - Claude Code

public enum ClaudeCodeWire {
    public enum Event: Equatable {
        case text(String)
        case result(text: String, isError: Bool)
    }

    /// One `user` message for `claude -p --input-format stream-json`.
    /// The CLI runs a fresh session per request, so earlier turns travel as text.
    public static func inputLine(_ request: AIRequest) throws -> Data {
        var content: [[String: Any]] = request.jpegImages.map {
            [
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()],
            ]
        }
        content.append(["type": "text", "text": request.textWithHistory])

        var line = try JSONSerialization.data(withJSONObject: [
            "type": "user",
            "message": ["role": "user", "content": content],
        ])
        line.append(0x0A)
        return line
    }

    public static func arguments(model: String, system: String) -> [String] {
        [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", model,
            // No tools: on-screen text can shape the answer but can't make it act.
            "--tools", "",
            // Skip the user's hooks, plugins and MCP servers to keep each turn fast and isolated.
            "--setting-sources", "",
            "--strict-mcp-config",
            "--no-session-persistence",
            "--system-prompt", system,
        ]
    }

    public static func event(fromLine line: String) -> Event? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return nil
        }
        switch object["type"] as? String {
        case "stream_event":
            guard let event = object["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String
            else { return nil }
            return .text(text)
        case "result":
            let isError = (object["is_error"] as? Bool) ?? (object["subtype"] as? String != "success")
            return .result(text: object["result"] as? String ?? "", isError: isError)
        default:
            return nil
        }
    }
}
