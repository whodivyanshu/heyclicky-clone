import Foundation

/// What the keyboard would land on, read from the frontmost app just before a key press.
public struct KeyContext: Equatable, Sendable {
    public var appName: String
    public var windowTitle: String
    /// The focused element's accessibility role and subrole, such as "AXTextArea". Empty if the app doesn't say.
    public var focusedRole: String
    public var focusedLabel: String
    /// The button Return would press in the focused window.
    public var defaultButton: String

    public init(appName: String = "", windowTitle: String = "", focusedRole: String = "", focusedLabel: String = "", defaultButton: String = "") {
        self.appName = appName
        self.windowTitle = windowTitle
        self.focusedRole = focusedRole
        self.focusedLabel = focusedLabel
        self.defaultButton = defaultButton
    }
}

/// Decides, in code, which steps need a yes from the user. The model can ask for more confirmations but can't skip these.
public enum RiskRules {
    private static let riskyWords = try! NSRegularExpression(
        pattern: #"\b(send|sending|post|publish|tweet|submit|delete|remove|erase|trash|discard|pay|payment|buy|purchase|checkout|check out|place order|order now|subscribe|unsubscribe|install|uninstall|sign in|signin|sign up|signup|sign out|log in|login|log out|logout|approve|confirm|authorize|authorise|allow|grant|accept|agree|transfer|deploy|merge|reset|wipe|call)\b"#,
        options: [.caseInsensitive]
    )
    /// Word boundaries are unreliable with Devanagari vowel signs, so these match anywhere in the label.
    private static let riskyHindi = ["भेज", "हटा", "मिटा", "भुगतान", "खरीद", "पुष्टि"]

    private static let messagingApps = ["whatsapp", "messages", "slack", "telegram", "discord", "signal", "teams", "mail", "outlook", "messenger", "wechat"]
    /// Page titles in a browser. Only names distinctive enough not to show up in ordinary page titles.
    private static let messagingSites = ["whatsapp", "gmail", "slack", "telegram", "discord", "outlook", "messenger", "linkedin", "instagram"]

    private static let returnKey: UInt16 = 36
    private static let deleteKeys: Set<UInt16> = [51, 117]
    private static let spaceKey: UInt16 = 49
    private static let dKey: UInt16 = 2

    /// The first label that sounds like something hard to take back.
    public static func riskyLabel(in labels: [String]) -> String? {
        labels.first { label in
            riskyWords.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil
                || riskyHindi.contains { containsScalars(label, $0) }
        }
    }

    /// Swift compares whole characters, and "भेजें" doesn't contain "भेज" that way, because the vowel sign is part of the last character.
    private static func containsScalars(_ text: String, _ part: String) -> Bool {
        text.range(of: part, options: .literal) != nil
    }

    public static func isMessaging(appName: String, windowTitle: String) -> Bool {
        let app = appName.lowercased(), title = windowTitle.lowercased()
        return messagingApps.contains(where: app.contains) || messagingSites.contains(where: title.contains)
    }

    public static func keyNeedsConfirmation(_ text: String, context: KeyContext) -> Bool {
        guard let combo = KeyCombo.parse(text) else { return false }
        let label = context.focusedLabel.lowercased()
        let role = context.focusedRole.lowercased()
        let onRiskyButton = (role.contains("button") || role.contains("link")) && riskyLabel(in: [context.focusedLabel]) != nil

        switch combo.keyCode {
        case returnKey:
            // Shift+Return adds a line in chat apps. Command, Control or Option+Return usually sends.
            if !combo.modifiers.subtracting([.shift]).isEmpty { return true }
            if !combo.modifiers.isEmpty { return false }
            if onRiskyButton || riskyLabel(in: [context.defaultButton]) != nil { return true }
            guard isMessaging(appName: context.appName, windowTitle: context.windowTitle) else { return false }
            let isSearch = role.contains("search") || ["search", "find", "खोज"].contains { containsScalars(label, $0) }
            return !isSearch
        case spaceKey:
            return onRiskyButton
        case _ where deleteKeys.contains(combo.keyCode):
            // In a text box this removes a character. Anywhere else it can delete the selected item.
            return !(role.contains("textarea") || role.contains("textfield") || role.contains("searchfield") || role.contains("combobox"))
        case dKey:
            // Mail's send shortcut.
            return combo.modifiers == [.command, .shift]
        default:
            return false
        }
    }
}

/// Reads a spoken answer to "should I go ahead?". Anything unclear counts as no answer, never as a yes.
public enum ConfirmationRules {
    private static let refusals = ["no", "nope", "nah", "don't", "dont", "do not", "stop", "cancel", "wait", "never", "nahi", "nahin", "nai", "mat", "ruko", "नहीं", "मत", "रुको", "रुकिए"]
    private static let approvals: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "confirm", "confirmed", "correct", "go ahead", "do it", "send it", "send", "yes please",
        "haan", "han", "haa", "ha", "ji", "ji haan", "theek hai", "thik hai", "kar do", "bhej do",
        "हाँ", "हां", "जी", "जी हाँ", "जी हां", "ठीक है", "कर दो", "कर दीजिए", "भेज दो", "भेज दीजिए", "यस", "ओके",
    ]
    private static let leadingApprovals: Set<String> = ["yes", "yeah", "yep", "yup", "haan", "हाँ", "हां"]
    private static let longestApproval = 6

    /// True for yes, false for no, nil if it isn't clear.
    public static func decision(from transcript: String) -> Bool? {
        let words = transcript.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.nonBaseCharacters).union(.decimalDigits).union(CharacterSet(charactersIn: "'’")).inverted)
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "’", with: "'") }
        guard !words.isEmpty else { return nil }
        let text = words.joined(separator: " ")

        let padded = " \(text) "
        if refusals.contains(where: { padded.contains(" \($0) ") }) { return false }
        if approvals.contains(text) { return true }
        // "Yes, send it" is clear. "Okay so what about..." isn't, which is why only a plain yes can start a longer answer.
        if words.count <= longestApproval, leadingApprovals.contains(words[0]) { return true }
        return nil
    }
}
