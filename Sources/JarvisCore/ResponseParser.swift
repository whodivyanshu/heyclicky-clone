import Foundation

public struct PointTag: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var label: String?
    public var screen: Int?
    /// Set only on guided targets: how far from the center, in image pixels, counts as a click on it.
    public var radius: Double?

    public init(x: Double, y: Double, label: String? = nil, screen: Int? = nil, radius: Double? = nil) {
        self.x = x
        self.y = y
        self.label = label
        self.screen = screen
        self.radius = radius
    }
}

/// One step of a reply, in the order it should happen.
public enum Beat: Equatable, Sendable {
    case say(String)
    case point(PointTag)
    /// A guided step: point here, then wait for the user to click it.
    case target(PointTag)
    /// Point here, then click it on the user's behalf.
    case click(PointTag)
    /// Something to do on the Mac, such as opening an app.
    case action(ActionTag)
    /// The model isn't finished: look at a new screenshot and ask it for the next step.
    case next
}

/// Turns streamed model text into speakable sentences and pointing tags.
///
/// Chunks can split anywhere, including inside a tag, so a possible tag is held
/// back until it is complete. Tags never reach the speech synthesizer.
public struct ResponseParser {
    private var pending = ""
    private var sentence = ""
    private static let tagStarts = ["[POINT:", "[TARGET:", "[CLICK:", "[NEXT]"] + ActionKind.allCases.map { "[\($0.rawValue):" }
    private static let maxTagLength = 2000

    private static let tagPattern = try! NSRegularExpression(
        pattern: #"^\[POINT:\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)(?:\s*:\s*(?!screen\s*\d)([^\]:]*?))?(?:\s*:\s*screen\s*(\d+))?\s*\]$"#,
        options: [.caseInsensitive]
    )
    private static let targetPattern = try! NSRegularExpression(
        pattern: #"^\[TARGET:\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)(?:\s*:\s*(?!screen\s*\d)([^\]:]*?))?(?:\s*:\s*screen\s*(\d+))?\s*\]$"#,
        options: [.caseInsensitive]
    )
    private static let actionPattern = try! NSRegularExpression(
        pattern: #"^\[(OPEN_APP|QUIT_APP|OPEN_URL|FIND_FILE|TYPE|KEY):\s*([^\]\n]+?)\s*\]$"#,
        options: [.caseInsensitive]
    )
    private static let nonePattern = try! NSRegularExpression(
        pattern: #"^\[POINT:\s*none\s*\]$"#,
        options: [.caseInsensitive]
    )

    public init() {}

    public mutating func feed(_ chunk: String) -> [Beat] {
        pending += chunk
        var beats: [Beat] = []

        while let open = pending.firstIndex(of: "[") {
            sentence += pending[..<open]
            pending = String(pending[open...])

            if let close = pending.firstIndex(of: "]") {
                let candidate = String(pending[...close])
                pending = String(pending[pending.index(after: close)...])
                if let tag = Self.parseTag(candidate) {
                    beats += flushSentence()
                    beats.append(.point(tag))
                } else if let tag = Self.parseTarget(candidate) {
                    beats += flushSentence()
                    beats.append(.target(tag))
                } else if let tag = Self.parseClick(candidate) {
                    beats += flushSentence()
                    beats.append(.click(tag))
                } else if let tag = Self.parseAction(candidate) {
                    beats += flushSentence()
                    beats.append(.action(tag))
                } else if candidate.uppercased() == "[NEXT]" {
                    beats += flushSentence()
                    beats.append(.next)
                } else if !Self.matches(Self.nonePattern, candidate) {
                    sentence += candidate
                }
            } else if Self.couldBecomeTag(pending) {
                beats += completedSentences()
                return beats
            } else {
                sentence.append("[")
                pending.removeFirst()
            }
        }

        sentence += pending
        pending = ""
        beats += completedSentences()
        return beats
    }

    /// Call when the stream ends. An unterminated tag is dropped rather than spoken.
    public mutating func finish() -> [Beat] {
        let upper = pending.uppercased()
        if !Self.tagStarts.contains(where: upper.hasPrefix) {
            sentence += pending
        }
        pending = ""
        return flushSentence()
    }

    private static func couldBecomeTag(_ text: String) -> Bool {
        guard text.count < maxTagLength else { return false }
        let upper = text.uppercased()
        return tagStarts.contains { upper.hasPrefix($0) || $0.hasPrefix(upper) }
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func parseTag(_ text: String) -> PointTag? {
        guard let match = tagPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        guard let x = group(1).flatMap(Double.init), let y = group(2).flatMap(Double.init) else {
            return nil
        }
        let label = group(3)?.trimmingCharacters(in: .whitespaces)
        return PointTag(
            x: x,
            y: y,
            label: (label?.isEmpty ?? true) ? nil : label,
            screen: group(4).flatMap(Int.init)
        )
    }

    /// A click is written exactly like a point, apart from its name.
    static func parseClick(_ text: String) -> PointTag? {
        let start = "[CLICK:"
        guard text.uppercased().hasPrefix(start) else { return nil }
        return parseTag("[POINT:" + text.dropFirst(start.count))
    }

    static func parseAction(_ text: String) -> ActionTag? {
        guard let match = actionPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let kindRange = Range(match.range(at: 1), in: text),
              let valueRange = Range(match.range(at: 2), in: text),
              let kind = ActionKind(rawValue: text[kindRange].uppercased())
        else { return nil }
        return ActionTag(kind: kind, value: String(text[valueRange]))
    }

    static func parseTarget(_ text: String) -> PointTag? {
        guard let match = targetPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        guard let x = group(1).flatMap(Double.init),
              let y = group(2).flatMap(Double.init),
              let radius = group(3).flatMap(Double.init)
        else { return nil }
        let label = group(4)?.trimmingCharacters(in: .whitespaces)
        return PointTag(
            x: x,
            y: y,
            label: (label?.isEmpty ?? true) ? nil : label,
            screen: group(5).flatMap(Int.init),
            radius: radius
        )
    }

    private mutating func completedSentences() -> [Beat] {
        var beats: [Beat] = []
        var start = sentence.startIndex
        var index = start
        while index < sentence.endIndex {
            let character = sentence[index]
            let next = sentence.index(after: index)
            let endsAtTerminator = "。！？".contains(character)
                || (".!?…".contains(character) && next < sentence.endIndex && sentence[next].isWhitespace)
            if character.isNewline || endsAtTerminator {
                if let beat = Self.sayBeat(String(sentence[start..<next])) { beats.append(beat) }
                start = next
            }
            index = next
        }
        sentence = String(sentence[start...])
        return beats
    }

    private mutating func flushSentence() -> [Beat] {
        var beats = completedSentences()
        if let beat = Self.sayBeat(sentence) { beats.append(beat) }
        sentence = ""
        return beats
    }

    /// Removes markdown the synthesizer would read aloud, and skips text with nothing to say.
    private static func sayBeat(_ raw: String) -> Beat? {
        let cleaned = raw
            .replacingOccurrences(of: #"[*_`#]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return nil }
        return .say(cleaned)
    }

    /// The reply text with tags removed, for conversation history.
    public static func spokenText(of reply: String) -> String {
        var parser = ResponseParser()
        let beats = parser.feed(reply) + parser.finish()
        return beats.compactMap { beat -> String? in
            if case .say(let text) = beat { return text }
            return nil
        }.joined(separator: " ")
    }
}
