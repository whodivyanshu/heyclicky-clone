import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// What goes into screen memory, decided before anything is written to disk.
public enum ScreenMemoryRules {
    public static let maxTextLength = 20_000
    /// A screen this similar to the last one saved has nothing new worth keeping.
    public static let sameScreenOverlap = 0.85

    private static let privateApps = ["1password", "bitwarden", "lastpass", "dashlane", "keychainaccess", "passwords", "protonpass", "enpass", "keeper"]
    private static let privateTitles = ["private browsing", "incognito", "inprivate"]

    /// Password managers and private browser windows are never remembered.
    public static func isPrivate(appName: String, windowTitle: String) -> Bool {
        let app = AppMatcher.normalized(appName)
        let title = windowTitle.lowercased()
        return privateApps.contains(where: app.contains) || privateTitles.contains(where: title.contains)
    }

    private static let cardNumbers = try! NSRegularExpression(pattern: #"\b(?:\d[ -]?){13,19}\b"#)
    private static let labelledSecrets = try! NSRegularExpression(
        pattern: #"(?i)\b(password|passcode|passwd|api[ _-]?key|secret|token|otp)\b(\s*[:=]\s*)\S+"#
    )
    private static let apiKeys = try! NSRegularExpression(pattern: #"\b(?:sk|pk|ghp|gho|xox[abp]|AIza)[-_A-Za-z0-9]{16,}\b"#)

    /// Removes what looks like a card number, key or password, and limits the length.
    public static func redacted(_ text: String) -> String {
        var result = text
        func replace(_ regex: NSRegularExpression, with template: String) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        replace(cardNumbers, with: "[hidden]")
        replace(labelledSecrets, with: "$1$2[hidden]")
        replace(apiKeys, with: "[hidden]")
        return String(result.prefix(maxTextLength))
    }

    public static func isWorthSaving(_ text: String, after previous: String?) -> Bool {
        let lines = Set(text.split(whereSeparator: \.isNewline).map(String.init))
        guard !lines.isEmpty else { return false }
        guard let previous else { return true }
        let earlier = Set(previous.split(whereSeparator: \.isNewline).map(String.init))
        let total = lines.union(earlier).count
        return Double(lines.intersection(earlier).count) / Double(total) < sameScreenOverlap
    }

    /// Whole words in any order, with the last able to be the start of a word. Quoted, so nothing typed can act as search syntax.
    public static func matchQuery(_ query: String) -> String? {
        let words = query.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"" }.joined(separator: " ") + "*"
    }
}

public struct ScreenMemoryHit: Equatable, Sendable {
    public var date: Date
    public var app: String
    public var snippet: String
}

#if canImport(SQLite3)
/// Text read from the screen, stored in a full-text index on this Mac. Images are never kept.
/// Windows has no system SQLite, so the Windows app keeps its own copy of this index in `ScreenMemoryStore.cs`.
public final class ScreenMemoryDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init?(url: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Created first, so it's private from the moment it exists. SQLite gives its side files the same permissions.
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard sqlite3_open(url.path, &db) == SQLITE_OK,
              sqlite3_exec(db, "CREATE VIRTUAL TABLE IF NOT EXISTS screens USING fts5(body, app UNINDEXED, date UNINDEXED);", nil, nil, nil) == SQLITE_OK
        else {
            sqlite3_close(db)
            return nil
        }
    }

    deinit {
        sqlite3_close(db)
    }

    private func run(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }) {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        sqlite3_step(statement)
    }

    public func add(text: String, app: String, date: Date) {
        run("INSERT INTO screens (body, app, date) VALUES (?, ?, ?);") { statement in
            sqlite3_bind_text(statement, 1, text, -1, Self.transient)
            sqlite3_bind_text(statement, 2, app, -1, Self.transient)
            sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)
        }
    }

    /// Newest first.
    public func search(_ query: String, limit: Int = 20) -> [ScreenMemoryHit] {
        guard let match = ScreenMemoryRules.matchQuery(query) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        let sql = "SELECT date, app, snippet(screens, 0, '', '', ' … ', 24) FROM screens WHERE screens MATCH ? ORDER BY CAST(date AS REAL) DESC LIMIT ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, match, -1, Self.transient)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var hits: [ScreenMemoryHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let app = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let snippet = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            hits.append(ScreenMemoryHit(date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)), app: app, snippet: snippet))
        }
        return hits
    }

    public func removeEntries(before date: Date) {
        run("DELETE FROM screens WHERE CAST(date AS REAL) < ?;") { sqlite3_bind_double($0, 1, date.timeIntervalSince1970) }
    }

    /// Deletes everything and shrinks the file, so the text doesn't linger inside it.
    public func clear() {
        run("DELETE FROM screens;")
        run("INSERT INTO screens(screens) VALUES('rebuild');")
        run("VACUUM;")
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM screens;", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
    }
}
#endif
