import Foundation

/// What sets a routine off: a phrase they say, or a time on chosen days.
public enum RoutineTrigger: Codable, Equatable, Sendable {
    case phrase(String)
    /// `days` uses Calendar's weekday numbers, where Sunday is 1.
    case schedule(days: Set<Int>, hour: Int, minute: Int)

    private static let dayNames: [String: Int] = [
        "sun": 1, "sunday": 1, "mon": 2, "monday": 2, "tue": 3, "tues": 3, "tuesday": 3, "wed": 4, "wednesday": 4,
        "thu": 5, "thur": 5, "thurs": 5, "thursday": 5, "fri": 6, "friday": 6, "sat": 7, "saturday": 7,
    ]

    /// `say focus mode`, `daily 09:00`, `weekdays 18:30`, `weekends 10:00` or `mon,thu 08:00`.
    public static func parse(_ text: String) -> RoutineTrigger? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("say ") {
            let phrase = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            return AppMatcher.normalized(phrase).isEmpty ? nil : .phrase(phrase)
        }
        let parts = lowered.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 2 else { return nil }
        let clock = parts[1].split(separator: ":").map { Int($0) }
        guard clock.count == 2, let hour = clock[0], let minute = clock[1], (0...23).contains(hour), (0...59).contains(minute) else { return nil }

        let days: Set<Int>
        switch parts[0] {
        case "daily", "everyday": days = Set(1...7)
        case "weekdays": days = Set(2...6)
        case "weekends": days = [1, 7]
        default:
            let named = parts[0].split(separator: ",").map { dayNames[String($0)] }
            guard !named.isEmpty, !named.contains(where: { $0 == nil }) else { return nil }
            days = Set(named.compactMap { $0 })
        }
        return .schedule(days: days, hour: hour, minute: minute)
    }

    /// Short words for the Settings list.
    public var summary: String {
        switch self {
        case .phrase(let phrase):
            return "When you say \"\(phrase)\""
        case .schedule(let days, let hour, let minute):
            let names = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
            let label: String
            if days.count == 7 {
                label = "Every day"
            } else if days == Set(2...6) {
                label = "Weekdays"
            } else if days == [1, 7] {
                label = "Weekends"
            } else {
                label = days.sorted().compactMap { names[$0] }.joined(separator: ", ")
            }
            return label + String(format: " at %02d:%02d", hour, minute)
        }
    }
}

public struct Routine: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var trigger: RoutineTrigger
    /// What Jarvis is asked to do, in the same words a person would say.
    public var request: String
    public var lastRun: Date?

    public init(id: UUID = UUID(), name: String, trigger: RoutineTrigger, request: String, lastRun: Date? = nil) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.request = request
        self.lastRun = lastRun
    }

    /// `name|when|request`, as in `[ADD_ROUTINE:focus|say focus mode|quit Slack]`.
    public static func parse(_ text: String) -> Routine? {
        let parts = text.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 3, !parts[0].isEmpty, !parts[2].isEmpty, let trigger = RoutineTrigger.parse(parts[1]) else { return nil }
        return Routine(name: String(parts[0].prefix(60)), trigger: trigger, request: String(parts[2].prefix(1000)))
    }
}

public struct RoutineBook: Codable, Equatable, Sendable {
    public static let maxRoutines = 30
    /// A Mac that wakes up a little late still runs the routine. Hours late, it would just be a surprise.
    public static let grace: TimeInterval = 5 * 60

    private static let spokenExtras: Set<String> = ["hey", "ok", "okay", "jarvis", "please", "start", "run", "activate", "begin", "my", "the", "routine"]

    public private(set) var routines: [Routine] = []

    public init(routines: [Routine] = []) {
        self.routines = routines
    }

    /// Adds a routine, replacing one with the same name. Returns false once the book is full.
    @discardableResult
    public mutating func add(_ routine: Routine) -> Bool {
        let key = AppMatcher.normalized(routine.name)
        if let index = routines.firstIndex(where: { AppMatcher.normalized($0.name) == key }) {
            routines[index] = routine
            return true
        }
        guard routines.count < Self.maxRoutines else { return false }
        routines.append(routine)
        return true
    }

    public mutating func remove(id: UUID) {
        routines.removeAll { $0.id == id }
    }

    /// Removes the routine with this name and returns it.
    public mutating func remove(named name: String) -> Routine? {
        guard let match = AppMatcher.best(for: name, among: routines.map(\.name)),
              let index = routines.firstIndex(where: { $0.name == match })
        else { return nil }
        return routines.remove(at: index)
    }

    /// The routine whose phrase is all they said, so a sentence that merely mentions it still goes to the AI.
    public func routine(matching transcript: String) -> Routine? {
        let said = Self.withoutExtras(transcript)
        guard !said.isEmpty else { return nil }
        return routines.first { routine in
            guard case .phrase(let phrase) = routine.trigger else { return false }
            return Self.withoutExtras(phrase) == said
        }
    }

    private static func withoutExtras(_ text: String) -> String {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let kept = words.filter { !spokenExtras.contains($0) }
        // A phrase made of nothing but these words still has to be able to match.
        return (kept.isEmpty ? words : kept).joined()
    }

    /// Scheduled routines whose time has just come and that haven't run for it yet.
    public func due(at now: Date, calendar: Calendar = .current) -> [Routine] {
        routines.filter { routine in
            guard case .schedule(let days, let hour, let minute) = routine.trigger,
                  days.contains(calendar.component(.weekday, from: now)),
                  let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now),
                  now >= fire, now.timeIntervalSince(fire) <= Self.grace
            else { return false }
            return (routine.lastRun ?? .distantPast) < fire
        }
    }

    public mutating func markRan(_ id: UUID, at date: Date) {
        guard let index = routines.firstIndex(where: { $0.id == id }) else { return }
        routines[index].lastRun = date
    }
}
