import Foundation

/// Things Jarvis can do on the Mac when asked. Each one is low risk: none of them
/// runs code from a file, types, clicks, or deletes anything.
public enum ActionKind: String, Equatable, Sendable, CaseIterable {
    case openApp = "OPEN_APP"
    case quitApp = "QUIT_APP"
    case openURL = "OPEN_URL"
    case findFile = "FIND_FILE"
}

public struct ActionTag: Equatable, Sendable {
    public var kind: ActionKind
    public var value: String

    public init(kind: ActionKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

public enum AppMatcher {
    /// Speech and models vary the spelling ("chat GPT", "Chat-GPT"), so compare letters and digits only.
    static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The closest app name, or nil if nothing is a believable match.
    public static func best(for query: String, among names: [String]) -> String? {
        let wanted = normalized(query)
        guard !wanted.isEmpty else { return nil }
        let candidates = names.map { (name: $0, key: normalized($0)) }.filter { !$0.key.isEmpty }
        func shortest(_ matches: [(name: String, key: String)]) -> String? {
            matches.min { $0.key.count < $1.key.count }?.name
        }

        if let exact = candidates.first(where: { $0.key == wanted }) { return exact.name }
        // Short fragments would match too many unrelated apps.
        if wanted.count >= 3, let match = shortest(candidates.filter { $0.key.hasPrefix(wanted) }) { return match }
        if wanted.count >= 3, let match = shortest(candidates.filter { $0.key.contains(wanted) }) { return match }
        return bestWithExtraWords(query: query, candidates: candidates)
    }

    /// Covers extra words, such as "ChatGPT desktop app" or "chat GPT please". Only whole words count,
    /// so "Photoshop" never opens Photos.
    private static func bestWithExtraWords(query: String, candidates: [(name: String, key: String)]) -> String? {
        let words = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { normalized(String($0)) }
        var runs = Set<String>()
        for start in words.indices {
            var run = ""
            for word in words[start...] {
                run += word
                runs.insert(run)
            }
        }
        return candidates
            .filter { $0.key.count >= 3 && runs.contains($0.key) }
            .max { $0.key.count < $1.key.count }?
            .name
    }
}

public enum ActionRules {
    /// Web addresses only. Other schemes can launch apps or run things, so they're refused.
    public static func webURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  url.host?.isEmpty == false
            else { return nil }
            return url
        }
        // A bare domain like youtube.com. "javascript:alert(1)" has no dot before its colon, and is refused.
        guard let host = trimmed.split(separator: "/").first, host.contains("."), !trimmed.contains(":") else {
            return nil
        }
        return URL(string: "https://\(trimmed)")
    }
}
