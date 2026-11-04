import Foundation

/// A control the frontmost app reports through Accessibility, in screenshot pixels.
public struct ScreenControl: Equatable, Sendable {
    public var role: String
    public var label: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var screen: Int

    public init(role: String, label: String, x: Double, y: Double, width: Double, height: Double, screen: Int) {
        self.role = role
        self.label = Self.clean(label)
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.screen = screen
    }

    /// Labels come from apps and web pages, so they can't be allowed to look like tags or break out of their line.
    static func clean(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: #"[\[\]"\n\r\t]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(flattened.prefix(60))
    }

    func contains(x pointX: Double, y pointY: Double) -> Bool {
        abs(pointX - x) <= width / 2 && abs(pointY - y) <= height / 2
    }
}

public enum ControlMatcher {
    /// How far a model's estimate, in image pixels, can be from the control it named.
    static let snapDistance = 80.0

    /// Moves a click onto the real control the model named when its estimate landed just outside it.
    public static func snap(_ tag: PointTag, to controls: [ScreenControl]) -> PointTag {
        let screen = tag.screen ?? 1
        let nearby = controls.filter { $0.screen == screen }
        // Already on a real control, so the model's choice stands.
        if nearby.contains(where: { $0.contains(x: tag.x, y: tag.y) }) { return tag }
        guard let label = tag.label else { return tag }
        let wanted = words(in: label)
        guard !wanted.isEmpty else { return tag }

        let match = nearby
            .filter { !wanted.isDisjoint(with: words(in: $0.label)) }
            .map { (control: $0, distance: hypot($0.x - tag.x, $0.y - tag.y)) }
            .filter { $0.distance <= snapDistance }
            .min { $0.distance < $1.distance }
        guard let match else { return tag }
        var snapped = tag
        snapped.x = match.control.x
        snapped.y = match.control.y
        return snapped
    }

    /// Generic words like "button" would match unrelated controls.
    private static func words(in text: String) -> Set<String> {
        let generic: Set<String> = ["button", "icon", "the", "box", "field", "link", "tab", "menu"]
        let found = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(found).subtracting(generic)
    }
}

public enum ContextRules {
    public static let maxContextLength = 8000

    /// The clipboard can hold passwords, so it's only read when they bring it up.
    public static func mentionsClipboard(_ transcript: String) -> Bool {
        let text = transcript.lowercased()
        return ["clipboard", "copied", "paste", "क्लिपबोर्ड", "कॉपी", "पेस्ट"].contains(where: text.contains)
    }

    /// Nil for empty text, and a capped length so one huge selection can't swamp the request.
    public static func limited(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxContextLength))
    }
}

/// Facts the user asked Jarvis to remember between launches.
public struct MemoryBook: Equatable, Sendable, Codable {
    public static let maxFacts = 50
    public static let maxLength = 200

    public private(set) var facts: [String] = []

    public init(facts: [String] = []) {
        self.facts = facts
    }

    /// Returns the fact as saved, or nil if it's empty. The oldest fact makes way once the book is full.
    @discardableResult
    public mutating func add(_ text: String) -> String? {
        let fact = String(
            text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
                .prefix(Self.maxLength)
        )
        guard !fact.isEmpty else { return nil }
        facts.removeAll { $0.caseInsensitiveCompare(fact) == .orderedSame }
        facts.append(fact)
        if facts.count > Self.maxFacts { facts.removeFirst(facts.count - Self.maxFacts) }
        return fact
    }

    /// Removes facts containing every word of the query, and returns them.
    @discardableResult
    public mutating func forget(matching query: String) -> [String] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let matches = facts.filter { fact in
            let lowered = fact.lowercased()
            return words.allSatisfy(lowered.contains)
        }
        facts.removeAll(where: matches.contains)
        return matches
    }

    public mutating func remove(_ fact: String) {
        facts.removeAll { $0 == fact }
    }

    public mutating func clear() {
        facts.removeAll()
    }
}
