import Foundation

/// One thing Jarvis did on the Mac, or tried to.
public struct ActivityEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    /// The request it was carrying out.
    public var request: String
    public var summary: String
    /// Why it didn't work, or why Jarvis didn't do it.
    public var failure: String?
    /// A screenshot's file name, if they chose to keep them.
    public var screenshot: String?

    public init(id: UUID = UUID(), date: Date, request: String, summary: String, failure: String? = nil, screenshot: String? = nil) {
        self.id = id
        self.date = date
        self.request = request
        self.summary = summary
        self.failure = failure
        self.screenshot = screenshot
    }
}

public struct ActivityBook: Codable, Equatable, Sendable {
    public static let maxEntries = 500

    /// Newest last.
    public private(set) var entries: [ActivityEntry] = []

    public init(entries: [ActivityEntry] = []) {
        self.entries = entries
    }

    /// Returns entries that made way, so their screenshots can be deleted too.
    @discardableResult
    public mutating func add(_ entry: ActivityEntry) -> [ActivityEntry] {
        entries.append(entry)
        guard entries.count > Self.maxEntries else { return [] }
        let removed = Array(entries.prefix(entries.count - Self.maxEntries))
        entries.removeFirst(removed.count)
        return removed
    }

    public mutating func clear() {
        entries.removeAll()
    }
}

/// One request and its reply, kept so they can find it again.
public struct ConversationEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var user: String
    public var assistant: String

    public init(id: UUID = UUID(), date: Date, user: String, assistant: String) {
        self.id = id
        self.date = date
        self.user = user
        self.assistant = assistant
    }
}

public struct ConversationBook: Codable, Equatable, Sendable {
    public static let maxEntries = 1000

    /// Newest last.
    public private(set) var entries: [ConversationEntry] = []

    public init(entries: [ConversationEntry] = []) {
        self.entries = entries
    }

    /// Adds a turn, or updates it, since a long job keeps adding to the same reply.
    public mutating func save(_ entry: ConversationEntry) {
        if let index = entries.lastIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
            return
        }
        entries.append(entry)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
    }

    /// Newest first. Every word has to appear in what they said or in the reply.
    public func search(_ query: String) -> [ConversationEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return entries.reversed() }
        return entries.reversed().filter { entry in
            let text = (entry.user + " " + entry.assistant).lowercased()
            return words.allSatisfy(text.contains)
        }
    }

    public mutating func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public mutating func clear() {
        entries.removeAll()
    }
}
