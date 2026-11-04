import Foundation

/// Simple requests that can run without asking the model, which saves several seconds.
///
/// This only accepts a sentence that is entirely one command and names something that really exists.
/// Anything else returns nil and goes to the model as usual, so being unsure costs time, not a wrong action.
public enum QuickCommand {
    private static let leadingFillers = [
        ["hey", "jarvis"], ["ok", "jarvis"], ["okay", "jarvis"], ["jarvis"], ["please"],
        ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"],
    ]
    private static let trailingFillers = [["right", "now"], ["for", "me"], ["thank", "you"], ["please"], ["now"], ["thanks"]]

    /// These words mean the request depends on the screen or says more than a name, so the model should read it.
    private static let needsModel: Set<String> = [
        "this", "that", "it", "these", "those", "here", "there", "them",
        "and", "then", "or", "but", "with", "in", "on", "at", "to", "from", "for", "of", "by", "if",
        "my", "your", "a", "an", "new", "next", "last", "first", "second", "third", "all",
        "tab", "tabs", "window", "windows", "file", "files", "folder", "link", "page", "document",
    ]
    private static let maxNameWords = 4

    /// Domain endings people say aloud. A list, because "open main.swift" or "readme.md" means a file, not a website.
    private static let webEndings: Set<String> = [
        "com", "org", "net", "io", "ai", "dev", "app", "co", "in", "uk", "edu", "gov", "me", "tv", "gg", "so", "xyz",
    ]

    /// The action for a transcript, or nil if the model should handle it. The app lists are only read when needed.
    public static func action(
        for transcript: String,
        installedApps: () -> [String],
        runningApps: () -> [String]
    ) -> ActionTag? {
        englishAction(for: transcript, installedApps: installedApps, runningApps: runningApps)
            ?? hindiAction(for: transcript, installedApps: installedApps, runningApps: runningApps)
    }

    private static func englishAction(
        for transcript: String,
        installedApps: () -> [String],
        runningApps: () -> [String]
    ) -> ActionTag? {
        guard var words = commandWords(in: transcript), let verb = words.first?.lowercased() else { return nil }
        words.removeFirst()

        let kind: Verb
        switch verb {
        case "open", "launch":
            kind = .open
        case "visit":
            kind = .visit
        case "quit", "exit":
            kind = .quit
        case "go", "switch":
            guard words.first?.lowercased() == "to" else { return nil }
            words.removeFirst()
            kind = verb == "go" ? .visit : .switchTo
        default:
            return nil
        }

        if words.first?.lowercased() == "the" { words.removeFirst() }
        if let last = words.last?.lowercased(), last == "app" || last == "application" { words.removeLast() }
        guard !words.isEmpty, words.count <= maxNameWords,
              words.allSatisfy({ !needsModel.contains($0.lowercased()) })
        else { return nil }
        return resolve(kind, name: words.joined(separator: " "), installedApps: installedApps, runningApps: runningApps)
    }

    private static func resolve(_ kind: Verb, name: String, installedApps: () -> [String], runningApps: () -> [String]) -> ActionTag? {
        switch kind {
        case .open:
            if let address = webAddress(name) { return ActionTag(kind: .openURL, value: address) }
            let apps = installedApps()
            // An exact app comes first, then a known site, so "open google" isn't taken for Google Chrome.
            if let app = AppMatcher.exact(for: name, among: apps) { return ActionTag(kind: .openApp, value: app) }
            if let site = knownWebsite(name) { return ActionTag(kind: .openURL, value: site) }
            return AppMatcher.wholeWords(for: name, among: apps).map { ActionTag(kind: .openApp, value: $0) }
        case .visit:
            return (webAddress(name) ?? knownWebsite(name)).map { ActionTag(kind: .openURL, value: $0) }
        case .switchTo:
            return AppMatcher.wholeWords(for: name, among: installedApps()).map { ActionTag(kind: .openApp, value: $0) }
        case .quit:
            return AppMatcher.wholeWords(for: name, among: runningApps()).map { ActionTag(kind: .quitApp, value: $0) }
        }
    }

    /// What to say once the action has run.
    public static func confirmation(for tag: ActionTag, hindi: Bool = false) -> String {
        guard hindi else { return OnDeviceRules.confirmation(for: tag) }
        switch tag.kind {
        case .openApp: return "\(tag.value) खोल रहा हूँ।"
        case .quitApp: return "\(tag.value) बंद कर रहा हूँ।"
        default: return "खोल रहा हूँ।"
        }
    }

    // MARK: - Hindi

    /// Hindi puts the verb last, as in "क्रोम खोलो" or "Chrome kholo". Longest first, so "बंद कर दो" isn't cut short.
    private static let hindiVerbs: [(words: String, verb: Verb)] = [
        ("खोल दीजिए", .open), ("खोल दीजिये", .open), ("खोल दो", .open), ("खोलिए", .open), ("खोलिये", .open), ("खोलें", .open), ("खोलो", .open),
        ("khol dijiye", .open), ("khol do", .open), ("kholiye", .open), ("kholo", .open),
        ("बंद कर दीजिए", .quit), ("बंद कर दीजिये", .quit), ("बंद कर दो", .quit), ("बंद कीजिए", .quit), ("बंद कीजिये", .quit), ("बंद करें", .quit), ("बंद करो", .quit),
        ("band kar dijiye", .quit), ("band kar do", .quit), ("band kijiye", .quit), ("band karo", .quit),
        ("पर जाइए", .visit), ("पर जाइये", .visit), ("पर जाओ", .visit), ("पे जाओ", .visit),
        ("par jaiye", .visit), ("par jao", .visit), ("pe jao", .visit),
    ]

    private static let hindiFillers: Set<String> = ["हे", "जार्विस", "जारविस", "कृपया", "प्लीज़", "प्लीज", "ज़रा", "जरा", "hey", "jarvis", "please", "zara"]

    /// These mean there's more to the request than a name, so the model should read it.
    private static let hindiNeedsModel: Set<String> = [
        "और", "फिर", "यह", "ये", "वह", "वो", "इस", "उस", "इसे", "उसे", "में", "से", "का", "की", "के", "नया", "नई", "सभी", "सब",
        "aur", "phir", "yeh", "ye", "woh", "wo", "isko", "usko", "mein", "se", "ka", "ki", "ke", "naya", "nayi", "sab",
    ]

    /// The recognizer writes most app names in Devanagari, which can't match a Latin app name by itself.
    private static let devanagariNames: [String: String] = [
        "क्रोम": "chrome", "गूगल क्रोम": "google chrome", "सफारी": "safari", "ब्रेव": "brave", "फायरफॉक्स": "firefox",
        "व्हाट्सएप": "whatsapp", "व्हाट्सऐप": "whatsapp", "वॉट्सएप": "whatsapp", "स्लैक": "slack", "टेलीग्राम": "telegram", "डिस्कॉर्ड": "discord",
        "नोट्स": "notes", "कैलकुलेटर": "calculator", "कैलेंडर": "calendar", "मेल": "mail", "फाइंडर": "finder", "संदेश": "messages",
        "स्पॉटिफाई": "spotify", "म्यूजिक": "music", "टर्मिनल": "terminal", "एक्सकोड": "xcode", "वीएस कोड": "visual studio code",
        "चैटजीपीटी": "chatgpt", "चैट जीपीटी": "chatgpt", "फोटोज़": "photos", "फोटोज": "photos", "सेटिंग्स": "system settings",
        "यूट्यूब": "youtube", "जीमेल": "gmail", "गूगल": "google", "गिटहब": "github", "रेडिट": "reddit", "नेटफ्लिक्स": "netflix",
        "इंस्टाग्राम": "instagram", "फेसबुक": "facebook", "लिंक्डइन": "linkedin", "ट्विटर": "twitter", "अमेज़न": "amazon", "अमेज़ॉन": "amazon", "अमेजन": "amazon",
    ]

    private static func hindiAction(for transcript: String, installedApps: () -> [String], runningApps: () -> [String]) -> ActionTag? {
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, ".!?।".contains(last) { text.removeLast() }
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = words.first, hindiFillers.contains(first.lowercased().trimmingCharacters(in: .punctuationCharacters)) { words.removeFirst() }
        guard !words.contains(where: { $0.last.map { ",;:.!?।".contains($0) } ?? false }) else { return nil }

        let joined = words.joined(separator: " ")
        let lowered = joined.lowercased()
        guard let match = hindiVerbs.first(where: { lowered.hasSuffix(" " + $0.words) }) else { return nil }
        var nameWords = String(joined.dropLast(match.words.count)).split(whereSeparator: \.isWhitespace).map(String.init)

        // "क्रोम को खोलो" and "क्रोम ऐप खोलो" mean the same as "क्रोम खोलो".
        if let last = nameWords.last?.lowercased(), last == "को" || last == "ko" { nameWords.removeLast() }
        if let last = nameWords.last?.lowercased(), ["ऐप", "एप", "एप्लिकेशन", "app"].contains(last) { nameWords.removeLast() }
        guard !nameWords.isEmpty, nameWords.count <= maxNameWords,
              nameWords.allSatisfy({ !hindiNeedsModel.contains($0.lowercased()) && !needsModel.contains($0.lowercased()) })
        else { return nil }

        let spoken = nameWords.joined(separator: " ")
        return resolve(match.verb, name: devanagariNames[spoken] ?? spoken, installedApps: installedApps, runningApps: runningApps)
    }

    private enum Verb {
        case open, visit, switchTo, quit
    }

    /// The words of the command with polite extras removed, or nil if it's more than one clause.
    private static func commandWords(in transcript: String) -> [String]? {
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, ".!?".contains(last) { text.removeLast() }
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)

        // "Hey Jarvis, can you open Chrome" has a comma that's fine, but any comma after this point means more clauses.
        var strippedFiller = true
        while strippedFiller {
            strippedFiller = false
            for filler in leadingFillers where matches(words.prefix(filler.count), filler) {
                words.removeFirst(filler.count)
                strippedFiller = true
                break
            }
        }
        guard !words.contains(where: { $0.last.map { ",;:.!?".contains($0) } ?? false }) else { return nil }

        strippedFiller = true
        while strippedFiller {
            strippedFiller = false
            for filler in trailingFillers where matches(words.suffix(filler.count), filler) {
                words.removeLast(filler.count)
                strippedFiller = true
                break
            }
        }
        return words
    }

    private static func matches(_ words: ArraySlice<String>, _ filler: [String]) -> Bool {
        words.count == filler.count && zip(words, filler).allSatisfy {
            $0.lowercased().trimmingCharacters(in: .punctuationCharacters) == $1
        }
    }

    /// A spoken web address such as "github.com" or "github dot com/settings".
    private static func webAddress(_ name: String) -> String? {
        let address = name.lowercased().replacingOccurrences(of: " dot ", with: ".")
        guard address.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+(/[^\s|]*)?$"#, options: .regularExpression) != nil,
              let host = address.split(separator: "/").first,
              let ending = host.split(separator: ".").last, webEndings.contains(String(ending)),
              ActionRules.webURL(from: address) != nil
        else { return nil }
        return address
    }

    private static func knownWebsite(_ name: String) -> String? {
        OnDeviceRules.knownWebsites[AppMatcher.normalized(name)]
    }
}
