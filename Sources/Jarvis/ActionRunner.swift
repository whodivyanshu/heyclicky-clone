import AppKit
import JarvisCore

struct ActionResult {
    /// Shown on the island, such as "Opened ChatGPT".
    var summary: String
    /// Spoken instead of the model's reply when the action didn't work.
    var failure: String?
}

/// Carries out the actions a reply asks for.
@MainActor
enum ActionRunner {
    static func progress(for tag: ActionTag) -> String {
        switch tag.kind {
        case .openApp: "Opening \(tag.value)…"
        case .quitApp: "Quitting \(tag.value)…"
        case .openURL: "Opening \(tag.value)…"
        case .findFile: "Searching for \(tag.value)…"
        }
    }

    static func run(_ tag: ActionTag) async -> ActionResult {
        switch tag.kind {
        case .openApp: await openApp(tag.value)
        case .quitApp: quitApp(tag.value)
        case .openURL: openURL(tag.value)
        case .findFile: await findFile(tag.value)
        }
    }

    // MARK: - Apps

    private static func openApp(_ query: String) async -> ActionResult {
        guard let app = findApp(query) else {
            return ActionResult(
                summary: "Couldn't find \(query)",
                failure: "I couldn't find an app called \(query) on this Mac."
            )
        }
        let name = app.deletingPathExtension().lastPathComponent
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            return ActionResult(summary: "Opened \(name)")
        } catch {
            return ActionResult(summary: "Couldn't open \(name)", failure: "\(name) wouldn't open.")
        }
    }

    /// Looks in every standard app folder, whether or not the app is in the Dock, then asks Spotlight.
    static func findApp(_ query: String) -> URL? {
        let manager = FileManager.default
        let folders = [
            "/Applications",
            "/Applications/Utilities",
            "\(manager.homeDirectoryForCurrentUser.path)/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices",
        ]
        var apps: [String: URL] = [:]
        for folder in folders {
            let contents = (try? manager.contentsOfDirectory(atPath: folder)) ?? []
            for item in contents where item.hasSuffix(".app") {
                let name = String(item.dropLast(4))
                // An earlier folder wins, so a user's copy comes before a system one.
                if apps[name] == nil { apps[name] = URL(fileURLWithPath: folder).appendingPathComponent(item) }
            }
        }
        if let match = AppMatcher.best(for: query, among: Array(apps.keys)) {
            return apps[match]
        }

        let escaped = query.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "*", with: "")
        let found = spotlight(["kMDItemContentType == \"com.apple.application-bundle\" && kMDItemDisplayName == \"*\(escaped)*\"cd"])
        let urls = found.map { URL(fileURLWithPath: $0) }
        guard let match = AppMatcher.best(for: query, among: urls.map { $0.deletingPathExtension().lastPathComponent }) else {
            return nil
        }
        return urls.first { $0.deletingPathExtension().lastPathComponent == match }
    }

    private static func quitApp(_ query: String) -> ActionResult {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        guard let match = AppMatcher.best(for: query, among: running.compactMap(\.localizedName)),
              let app = running.first(where: { $0.localizedName == match })
        else {
            return ActionResult(summary: "\(query) isn't running", failure: "\(query) isn't running.")
        }
        // A normal quit, so the app can still ask about unsaved work.
        app.terminate()
        return ActionResult(summary: "Asked \(match) to quit")
    }

    // MARK: - Web

    private static func openURL(_ text: String) -> ActionResult {
        guard let url = ActionRules.webURL(from: text), NSWorkspace.shared.open(url) else {
            return ActionResult(summary: "Couldn't open that address", failure: "I couldn't open that address.")
        }
        return ActionResult(summary: "Opened \(url.host ?? text)")
    }

    // MARK: - Files

    /// Shows the best match in Finder without opening it, so nothing runs.
    private static func findFile(_ query: String) async -> ActionResult {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let found = await Task.detached { spotlight(["-onlyin", home, "-name", query]) }.value
        let usable = found.filter { !$0.contains("/Library/") && !$0.contains("/.") }
        guard let path = usable.first else {
            return ActionResult(summary: "Couldn't find \(query)", failure: "I couldn't find a file matching \(query).")
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        return ActionResult(summary: "Found \(URL(fileURLWithPath: path).lastPathComponent)")
    }

    private nonisolated static func spotlight(_ arguments: [String]) -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
