import Foundation

/// Apple's on-device model is too small for the full prompt: it reports on screenshots nobody asked about,
/// opens apps by itself, invents tags and guesses coordinates. So code decides what each turn gets:
/// a request to do something gets tags and no screenshot, and anything else gets no tags.
public enum OnDeviceRules {
    private static let chat = """
    You are Jarvis, a friendly voice assistant on the user's Mac. Your words are spoken aloud.
    - Answer what they said in one or two short sentences, in plain words with no lists or emoji.
    - If they greet you or chat, just reply warmly.
    - If a screenshot is attached, answer from what you can clearly see in it. If you can't tell, say so. Without one, don't mention their screen.
    - You can't click, type or point at things. If they ask for that, say you can't do it with this model.
    - Never write square brackets.
    """

    private static let action = """
    You are Jarvis, a voice assistant on the user's Mac. Do what they ask by replying with exactly one of these tags and nothing else.
    [OPEN_APP:name] opens an app installed on the Mac.
    [QUIT_APP:name] quits an app.
    [OPEN_URL:address] opens a website. For a web search use: [OPEN_URL:google.com/search?q=the+words]
    [FIND_FILE:words] finds a file and shows it in Finder.
    [COPY]text[/COPY] puts text on their clipboard.
    [REMEMBER:full sentence] saves what they told you to remember.
    [FORGET:words] removes something they told you to forget.
    Use no other tags.
    """

    public static func system(for transcript: String, memories: [String] = []) -> String {
        let base = wantsAction(transcript) ? action : chat
        guard !memories.isEmpty else { return base }
        return base + "\n\nThings they told you to remember:\n" + memories.map { "- \($0)" }.joined(separator: "\n")
    }

    /// Words that ask Jarvis to do something, rather than to talk or look.
    public static func wantsAction(_ transcript: String) -> Bool {
        // "How do I open Safari?" is a question, not a request to open it.
        let first = transcript.lowercased().split { !$0.isLetter }.first.map(String.init) ?? ""
        guard !["how", "what", "whats", "why", "when", "who", "which", "is", "does", "do"].contains(first) else { return false }
        return !words(in: transcript).isDisjoint(with: [
            "open", "launch", "switch", "go", "visit", "browse", "quit", "close", "exit",
            "search", "google", "find", "locate", "copy", "remember", "forget",
        ])
    }

    /// Without a screenshot the model can't get distracted by the screen, and nothing is captured needlessly.
    public static func needsScreen(_ transcript: String) -> Bool {
        !wantsAction(transcript) && !words(in: transcript).isDisjoint(with: [
            "screen", "see", "look", "looking", "this", "that", "these", "here", "window", "page", "tab",
            "button", "error", "read", "explain", "summarize", "summarise", "showing", "display", "where",
        ])
    }

    /// Whether their own words asked for this action. The model's choice alone is never enough.
    public static func allows(_ tag: ActionTag, transcript: String) -> Bool {
        let said = words(in: transcript)
        switch tag.kind {
        case .openApp:
            return !said.isDisjoint(with: ["open", "launch", "switch", "go"]) && names(tag.value, transcript)
        case .quitApp:
            return !said.isDisjoint(with: ["quit", "close", "exit"]) && names(tag.value, transcript)
        case .openURL:
            return !said.isDisjoint(with: ["open", "go", "visit", "search", "google", "browse"])
        case .findFile:
            return !said.isDisjoint(with: ["find", "locate", "search"])
        case .copy:
            return said.contains("copy")
        case .remember:
            return said.contains("remember")
        case .forget:
            return said.contains("forget")
        case .typeText, .pressKey, .paste, .plan, .confirm:
            return false
        }
    }

    /// This model often opens well-known websites as if they were apps.
    static func correctingWebsite(_ tag: ActionTag) -> ActionTag {
        let websites = [
            "youtube": "youtube.com", "gmail": "mail.google.com", "google": "google.com",
            "reddit": "reddit.com", "github": "github.com", "netflix": "netflix.com",
            "instagram": "instagram.com", "facebook": "facebook.com", "linkedin": "linkedin.com",
            "twitter": "x.com", "amazon": "amazon.com",
        ]
        guard tag.kind == .openApp, let address = websites[squeezed(tag.value)] else { return tag }
        return ActionTag(kind: .openURL, value: address)
    }

    /// What to say after an action, since this model's own wording can describe something else entirely.
    static func confirmation(for tag: ActionTag) -> String {
        switch tag.kind {
        case .openApp: "Opening \(tag.value)."
        case .quitApp: "Quitting \(tag.value)."
        case .openURL: "Opening that for you."
        case .findFile: "Looking for it."
        case .copy: "It's on your clipboard."
        case .remember: "I'll remember that."
        case .forget: "Okay, I've forgotten that."
        case .typeText, .pressKey, .paste, .plan, .confirm: ""
        }
    }

    /// It sometimes writes these two without the brackets, which would read the tag aloud and save nothing.
    static func memoryTag(in text: String) -> ActionTag? {
        for kind in [ActionKind.remember, .forget] {
            guard let range = text.range(of: "\(kind.rawValue):", options: [.anchored, .caseInsensitive]) else { continue }
            let value = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return ActionTag(kind: kind, value: value) }
        }
        return nil
    }

    /// Tags it made up would otherwise be read aloud.
    static func withoutBrackets(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[[^\]]*\]?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Compares letters and digits only, since speech often splits names, as in "chat GPT".
    private static func names(_ app: String, _ transcript: String) -> Bool {
        let name = squeezed(app)
        return !name.isEmpty && squeezed(transcript).contains(name)
    }

    private static func squeezed(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}

/// Filters one reply from the on-device model as it streams.
public struct OnDeviceGuard {
    private let transcript: String
    private let isActionTurn: Bool
    private var stopped = false
    private var acted = false
    private var said: [String] = []

    public init(transcript: String) {
        self.transcript = transcript
        isActionTurn = OnDeviceRules.wantsAction(transcript)
    }

    /// The words that were let through, which is what was really said.
    public var spoken: String { said.joined(separator: " ") }

    /// Drops pointing and clicks. On a request to do something, the words come from here and only describe
    /// what really runs. `final` marks the end of the reply, when a request that did nothing says so.
    public mutating func filter(_ beats: [Beat], final: Bool = false) -> [Beat] {
        var kept: [Beat] = []
        for beat in beats where !stopped {
            switch beat {
            case .say(let text):
                if isActionTurn {
                    if let tag = OnDeviceRules.memoryTag(in: text) { run(tag, into: &kept) }
                } else {
                    let clean = OnDeviceRules.withoutBrackets(text)
                    guard !clean.isEmpty else { continue }
                    say(clean, into: &kept)
                }
            case .action(let tag):
                run(OnDeviceRules.correctingWebsite(tag), into: &kept)
            case .point, .target, .click, .next, .done:
                break
            }
        }
        if final, isActionTurn, !acted {
            stopped = true
            say("Sorry, I couldn't do that.", into: &kept)
        }
        return kept
    }

    /// One action per reply. Anything after it was planned around it, or around something that didn't happen.
    private mutating func run(_ tag: ActionTag, into kept: inout [Beat]) {
        stopped = true
        guard isActionTurn, OnDeviceRules.allows(tag, transcript: transcript) else { return }
        acted = true
        kept.append(.action(tag))
        say(OnDeviceRules.confirmation(for: tag), into: &kept)
    }

    private mutating func say(_ text: String, into kept: inout [Beat]) {
        said.append(text)
        kept.append(.say(text))
    }
}
