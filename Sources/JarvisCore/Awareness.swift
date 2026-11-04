import Foundation

/// Finds "hey Jarvis" in what the on-device recognizer has heard so far.
public enum WakeWord {
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:^|[\s,.!?।])(?:hey|hi|hello|ok|okay|हे|हेय|ओके)[\s,.!]+(?:jarvis|jervis|जार्विस|जारविस)(?=$|[\s,.!?।])[\s,.!?।]*"#,
        options: [.caseInsensitive]
    )

    /// What came after the wake phrase, which may be nothing yet. Nil if it hasn't been said.
    /// A bare "Jarvis" doesn't count, because people say the name in conversation and on video calls.
    public static func command(in transcript: String) -> String? {
        let range = NSRange(transcript.startIndex..., in: transcript)
        guard let match = pattern.matches(in: transcript, range: range).last,
              let end = Range(match.range, in: transcript)?.upperBound
        else { return nil }
        return String(transcript[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum FollowUpRules {
    private static let closers: Set<String> = [
        "thanks", "thank you", "thanks jarvis", "thank you jarvis", "ok thanks", "okay thanks", "ok thank you", "okay thank you",
        "no thanks", "no thank you", "thats all", "that is all", "never mind", "nevermind", "stop", "ok", "okay", "cool", "great", "got it",
        "धन्यवाद", "शुक्रिया", "ठीक है", "बस", "बस इतना ही", "रहने दो",
    ]

    /// Whether a follow-up is only them wrapping up, which doesn't need an answer.
    public static func endsConversation(_ transcript: String) -> Bool {
        let cleaned = transcript.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .components(separatedBy: CharacterSet.letters.union(.nonBaseCharacters).union(.decimalDigits).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return closers.contains(cleaned)
    }
}

/// Decides, on this Mac, whether text read from the screen is worth offering help with.
/// Nothing reaches the AI unless they accept the offer.
public struct ScreenWatchRules: Equatable, Sendable {
    /// So a bad day doesn't turn into a stream of interruptions.
    public static let quietPeriod: TimeInterval = 5 * 60
    /// The same problem can stay on screen for a long time, but it's only worth raising once in a while.
    public static let repeatAfter: TimeInterval = 60 * 60

    /// Specific phrases only. A plain "error" is on screen all the time in code and logs.
    private static let signals: [(pattern: String, name: String)] = [
        (#"\bbuild failed\b"#, "A build failed"),
        (#"\bcompilation failed\b|\bfailed to compile\b"#, "Something failed to compile"),
        (#"\bfatal error\b"#, "There's a fatal error"),
        (#"\buncaught (exception|error|typeerror|referenceerror)\b|\bunhandled (exception|rejection)\b"#, "There's an unhandled error"),
        (#"\btraceback \(most recent call last\)"#, "A Python script crashed"),
        (#"\bsegmentation fault\b"#, "A program crashed"),
        (#"\bnpm err!"#, "npm hit an error"),
        (#"\b\d+ tests? failed\b|\btests? failed\b"#, "Tests failed"),
        (#"\bconnection refused\b"#, "A connection was refused"),
        (#"\bpermission denied\b"#, "Permission was denied"),
        (#"\b500 internal server error\b"#, "A server error came up"),
        (#"\bsomething went wrong\b"#, "Something went wrong"),
    ]

    private var lastOffer: Date?
    private var lastBySignal: [String: Date] = [:]

    public init() {}

    /// What to offer help with for this screen text, or nil if it should stay quiet.
    public mutating func offer(forScreenText text: String, now: Date) -> String? {
        if let lastOffer, now.timeIntervalSince(lastOffer) < Self.quietPeriod { return nil }
        for signal in Self.signals where text.range(of: signal.pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            if let last = lastBySignal[signal.name], now.timeIntervalSince(last) < Self.repeatAfter { continue }
            lastOffer = now
            lastBySignal[signal.name] = now
            return signal.name
        }
        return nil
    }
}
