import Combine
import Foundation
import JarvisCore

/// Where Jarvis keeps its files. Everything here stays on this Mac and only this user can read it.
enum JarvisFiles {
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Jarvis", isDirectory: true)
    static let screenshots = folder.appendingPathComponent("Activity screenshots", isDirectory: true)

    static func load<Value: Decodable>(_ type: Value.Type, from name: String) -> Value? {
        (try? Data(contentsOf: folder.appendingPathComponent(name))).flatMap {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(type, from: $0)
        }
    }

    static func save(_ value: some Encodable, to name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        writePrivately(data, to: folder.appendingPathComponent(name))
    }

    static func writePrivately(_ data: Data, to url: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Past requests and replies, for the History page.
@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var book: ConversationBook
    private var pendingSave: Task<Void, Never>?
    private static let fileName = "conversations.json"

    init() {
        book = JarvisFiles.load(ConversationBook.self, from: Self.fileName) ?? ConversationBook()
    }

    func save(_ entry: ConversationEntry) {
        book.save(entry)
        // A long job updates its reply at every step, so wait for a quiet moment before writing.
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            JarvisFiles.save(self.book, to: Self.fileName)
        }
    }

    func remove(id: UUID) {
        book.remove(id: id)
        JarvisFiles.save(book, to: Self.fileName)
    }

    func clear() {
        pendingSave?.cancel()
        book.clear()
        JarvisFiles.save(book, to: Self.fileName)
    }
}

/// What Jarvis has done on the Mac, for the Activity page.
@MainActor
final class ActivityStore: ObservableObject {
    @Published private(set) var book: ActivityBook
    private static let fileName = "activity.json"

    init() {
        book = JarvisFiles.load(ActivityBook.self, from: Self.fileName) ?? ActivityBook()
    }

    func add(request: String, summary: String, failure: String?, screenshot: Data?) {
        var fileName: String?
        let id = UUID()
        if let screenshot {
            fileName = "\(id.uuidString).jpg"
            JarvisFiles.writePrivately(screenshot, to: JarvisFiles.screenshots.appendingPathComponent(fileName!))
        }
        let entry = ActivityEntry(id: id, date: Date(), request: String(request.prefix(300)), summary: summary, failure: failure, screenshot: fileName)
        deleteScreenshots(of: book.add(entry))
        JarvisFiles.save(book, to: Self.fileName)
    }

    func screenshotURL(for entry: ActivityEntry) -> URL? {
        entry.screenshot.map { JarvisFiles.screenshots.appendingPathComponent($0) }
    }

    func clear() {
        deleteScreenshots(of: book.entries)
        book.clear()
        JarvisFiles.save(book, to: Self.fileName)
    }

    private func deleteScreenshots(of entries: [ActivityEntry]) {
        for entry in entries {
            if let url = screenshotURL(for: entry) { try? FileManager.default.removeItem(at: url) }
        }
    }
}

@MainActor
final class RoutineStore: ObservableObject {
    @Published private(set) var book: RoutineBook
    private static let fileName = "routines.json"

    init() {
        book = JarvisFiles.load(RoutineBook.self, from: Self.fileName) ?? RoutineBook()
    }

    @discardableResult
    func add(_ routine: Routine) -> Bool {
        let added = book.add(routine)
        JarvisFiles.save(book, to: Self.fileName)
        return added
    }

    func remove(id: UUID) {
        book.remove(id: id)
        JarvisFiles.save(book, to: Self.fileName)
    }

    func remove(named name: String) -> Routine? {
        let removed = book.remove(named: name)
        JarvisFiles.save(book, to: Self.fileName)
        return removed
    }

    func markRan(_ id: UUID, at date: Date) {
        book.markRan(id, at: date)
        JarvisFiles.save(book, to: Self.fileName)
    }
}

@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var book: MeetingBook
    private static let fileName = "meetings.json"

    init() {
        book = JarvisFiles.load(MeetingBook.self, from: Self.fileName) ?? MeetingBook()
    }

    func save(_ note: MeetingNote) {
        book.save(note)
        JarvisFiles.save(book, to: Self.fileName)
    }

    func remove(id: UUID) {
        book.remove(id: id)
        JarvisFiles.save(book, to: Self.fileName)
    }
}

/// Text from the screen, searchable later. The file isn't even created until they turn this on.
@MainActor
final class ScreenMemoryStore: ObservableObject {
    @Published private(set) var count = 0
    private lazy var database = ScreenMemoryDatabase(url: JarvisFiles.folder.appendingPathComponent("screen-memory.sqlite"))
    private var lastSaved: String?
    private var lastPurge = Date.distantPast
    private static var fileExists: Bool {
        FileManager.default.fileExists(atPath: JarvisFiles.folder.appendingPathComponent("screen-memory.sqlite").path)
    }

    func refreshCount() {
        count = Self.fileExists ? database?.count ?? 0 : 0
    }

    func remember(_ text: String, app: String, keepingDays days: Int) {
        let clean = ScreenMemoryRules.redacted(text)
        guard ScreenMemoryRules.isWorthSaving(clean, after: lastSaved) else { return }
        lastSaved = clean
        database?.add(text: clean, app: app, date: Date())
        if Date().timeIntervalSince(lastPurge) > 3600 {
            lastPurge = Date()
            purge(keepingDays: days)
        }
        refreshCount()
    }

    func purge(keepingDays days: Int) {
        guard Self.fileExists else { return }
        database?.removeEntries(before: Date().addingTimeInterval(-Double(days) * 86400))
    }

    func search(_ query: String, limit: Int = 20) -> [ScreenMemoryHit] {
        guard Self.fileExists else { return [] }
        return database?.search(query, limit: limit) ?? []
    }

    func clear() {
        guard Self.fileExists else { return }
        database?.clear()
        lastSaved = nil
        refreshCount()
    }
}

/// Built-in teaching notes, plus any they've written themselves.
enum TeachingFiles {
    static let folder = JarvisFiles.folder.appendingPathComponent("Teaching packs", isDirectory: true)

    static func custom() -> [TeachingPack] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".md") }.sorted().compactMap { name in
            (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)).flatMap { TeachingPack.parse(fileName: name, text: $0) }
        }
    }

    static func all() -> [TeachingPack] {
        custom() + TeachingPack.builtIn
    }
}
