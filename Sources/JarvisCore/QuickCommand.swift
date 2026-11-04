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
        let name = words.joined(separator: " ")

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
    public static func confirmation(for tag: ActionTag) -> String {
        OnDeviceRules.confirmation(for: tag)
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
