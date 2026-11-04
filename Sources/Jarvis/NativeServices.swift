import AppKit
import Contacts
import EventKit
import JarvisCore

/// Uses Calendar, Reminders, Contacts, Mail and Shortcuts directly, without the screen.
/// Each framework asks for its own permission the first time it's needed.
enum NativeServices {
    private static let events = EKEventStore()
    private static let contacts = CNContactStore()
    private static let maxListed = 40
    private static let maxPeople = 5
    private static let shortcutTimeout: UInt64 = 120_000_000_000

    // MARK: - Permissions

    static var hasCalendar: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    static var hasReminders: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    static var hasContacts: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }

    static func requestCalendar() async -> Bool { (try? await events.requestFullAccessToEvents()) ?? false }
    static func requestReminders() async -> Bool { (try? await events.requestFullAccessToReminders()) ?? false }
    static func requestContacts() async -> Bool { (try? await contacts.requestAccess(for: .contacts)) ?? false }

    private static func denied(_ name: String, pane: String) -> ActionResult {
        Permissions.openSettings(for: pane)
        return ActionResult(summary: "Needs \(name) access", failure: "I need access to \(name). Turn on Jarvis in System Settings, then ask me again.")
    }

    // MARK: - Running tags

    static func run(_ tag: ActionTag) async -> ActionResult {
        switch tag.kind {
        case .events: return await readEvents(tag.value)
        case .reminders: return await readReminders()
        case .contact: return await lookUpContact(tag.value)
        case .addEvent: return await addEvent(tag.value)
        case .addReminder: return await addReminder(tag.value)
        case .draftMail: return await draftMail(tag.value)
        case .shortcut: return await runShortcut(tag.value)
        default: return ActionResult(summary: "")
        }
    }

    // MARK: - Calendar

    private static func readEvents(_ text: String) async -> ActionResult {
        guard let range = NativeRules.range(from: text) else {
            return ActionResult(summary: "Couldn't read that date", failure: "I couldn't work out which day you meant.")
        }
        if !hasCalendar, await !requestCalendar() { return denied("Calendar", pane: "Privacy_Calendars") }
        let predicate = events.predicateForEvents(withStart: range.start, end: range.end, calendars: nil)
        let found = events.events(matching: predicate).sorted { $0.compareStartDate(with: $1) == .orderedAscending }

        let day = DateFormatter()
        day.dateFormat = "EEE d MMM"
        let time = DateFormatter()
        time.timeStyle = .short
        let lines = found.prefix(maxListed).map { event -> String in
            let when = event.isAllDay
                ? "\(day.string(from: event.startDate)), all day"
                : "\(day.string(from: event.startDate)), \(time.string(from: event.startDate)) to \(time.string(from: event.endDate))"
            let place = event.location.flatMap { $0.isEmpty ? nil : " at \($0)" } ?? ""
            return "- \(when): \(event.title ?? "Untitled")\(place)"
        }
        return ActionResult(
            summary: "Checked your calendar",
            data: lines.isEmpty ? "No events \(text)." : "Events \(text):\n" + lines.joined(separator: "\n")
        )
    }

    private static func addEvent(_ text: String) async -> ActionResult {
        guard let new = NativeRules.newEvent(from: text) else {
            return ActionResult(summary: "Didn't add the event", failure: "I couldn't work out the title and time for that event.")
        }
        if !hasCalendar, await !requestCalendar() { return denied("Calendar", pane: "Privacy_Calendars") }
        guard let calendar = events.defaultCalendarForNewEvents else {
            return ActionResult(summary: "Didn't add the event", failure: "You don't have a calendar I can add events to.")
        }
        let event = EKEvent(eventStore: events)
        event.title = new.title
        event.startDate = new.start
        event.endDate = new.start.addingTimeInterval(TimeInterval(new.minutes * 60))
        event.calendar = calendar
        do {
            try events.save(event, span: .thisEvent, commit: true)
            return ActionResult(summary: "Added \"\(new.title)\" to your calendar")
        } catch {
            return ActionResult(summary: "Didn't add the event", failure: "Calendar wouldn't save that event.")
        }
    }

    // MARK: - Reminders

    private static func readReminders() async -> ActionResult {
        if !hasReminders, await !requestReminders() { return denied("Reminders", pane: "Privacy_Reminders") }
        let predicate = events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let lines: [String] = await withCheckedContinuation { continuation in
            events.fetchReminders(matching: predicate) { found in
                let format = DateFormatter()
                format.dateFormat = "EEE d MMM HH:mm"
                let lines = (found ?? []).prefix(maxListed).map { reminder -> String in
                    let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }.map { ", due \(format.string(from: $0))" } ?? ""
                    return "- \(reminder.title ?? "Untitled")\(due)"
                }
                continuation.resume(returning: lines)
            }
        }
        return ActionResult(
            summary: "Checked your reminders",
            data: lines.isEmpty ? "No unfinished reminders." : "Unfinished reminders:\n" + lines.joined(separator: "\n")
        )
    }

    private static func addReminder(_ text: String) async -> ActionResult {
        guard let new = NativeRules.newReminder(from: text) else {
            return ActionResult(summary: "Didn't add the reminder", failure: "I couldn't work out when that reminder is for.")
        }
        if !hasReminders, await !requestReminders() { return denied("Reminders", pane: "Privacy_Reminders") }
        guard let list = events.defaultCalendarForNewReminders() else {
            return ActionResult(summary: "Didn't add the reminder", failure: "You don't have a reminders list I can add to.")
        }
        let reminder = EKReminder(eventStore: events)
        reminder.title = new.title
        reminder.calendar = list
        if let due = new.due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        do {
            try events.save(reminder, commit: true)
            return ActionResult(summary: "Added the reminder \"\(new.title)\"")
        } catch {
            return ActionResult(summary: "Didn't add the reminder", failure: "Reminders wouldn't save that.")
        }
    }

    // MARK: - Contacts

    private static func lookUpContact(_ name: String) async -> ActionResult {
        if !hasContacts, await !requestContacts() { return denied("Contacts", pane: "Privacy_Contacts") }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        let found = await Task.detached {
            (try? contacts.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)) ?? []
        }.value
        guard !found.isEmpty else {
            return ActionResult(summary: "Checked your contacts", data: "No contact matches \(name).")
        }
        let lines = found.prefix(maxPeople).map { person -> String in
            let fullName = [person.givenName, person.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let emails = person.emailAddresses.map { $0.value as String }
            let phones = person.phoneNumbers.map(\.value.stringValue)
            let details = ["email: " + emails.joined(separator: ", "), "phone: " + phones.joined(separator: ", ")]
            return "- \(fullName.isEmpty ? person.organizationName : fullName), " + details.joined(separator: "; ")
        }
        return ActionResult(summary: "Checked your contacts", data: "Contacts matching \(name):\n" + lines.joined(separator: "\n"))
    }

    // MARK: - Mail

    /// Opens a draft in their mail app, with Jarvis taking no part in sending it.
    private static func draftMail(_ text: String) async -> ActionResult {
        guard let draft = NativeRules.mailDraft(from: text), let url = draft.url else {
            return ActionResult(summary: "Didn't start the email", failure: "I couldn't work out who that email is for.")
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        return opened
            ? ActionResult(summary: "Opened a draft\(draft.to.isEmpty ? "" : " to \(draft.to)")")
            : ActionResult(summary: "Didn't start the email", failure: "I couldn't open your mail app.")
    }

    // MARK: - Shortcuts

    private static let shortcutNames = NameCache()

    /// The most recent list of Shortcuts, so reading it never holds up a request.
    static var knownShortcuts: [String] { shortcutNames.names }

    static func refreshShortcuts() {
        Task.detached(priority: .utility) {
            guard let output = runProcess(["list"], timeout: 15) else { return }
            shortcutNames.names = output.split(separator: "\n").map(String.init)
        }
    }

    /// Only a name from their own list can run, so a made-up name can't reach the command.
    private static func runShortcut(_ name: String) async -> ActionResult {
        let names = await Task.detached { runProcess(["list"], timeout: 15) }.value?.split(separator: "\n").map(String.init) ?? []
        shortcutNames.names = names
        guard let match = AppMatcher.exact(for: name, among: names) else {
            return ActionResult(summary: "Couldn't find \(name)", failure: "You don't have a shortcut called \(name).")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", match]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ActionResult(summary: "Couldn't run \(match)", failure: "The shortcut \(match) wouldn't start.")
        }
        let status: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(shortcutTimeout)), execute: timeout)
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    timeout.cancel()
                    continuation.resume(returning: process.terminationStatus)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        return status == 0
            ? ActionResult(summary: "Ran \(match)")
            : ActionResult(summary: "\(match) didn't finish", failure: "The shortcut \(match) didn't finish.")
    }

    private static func runProcess(_ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stop.cancel()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    private final class NameCache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var names: [String] {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
