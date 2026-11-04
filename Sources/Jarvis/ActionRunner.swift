import AppKit
import Carbon.HIToolbox
import JarvisCore

struct ActionResult {
    /// Shown on the island, such as "Opened ChatGPT".
    var summary: String
    /// Spoken instead of the model's reply when the action didn't work.
    var failure: String?
    /// During a job the model can try another way after this failure. Safety refusals are never retried.
    var retryable = false
}

/// Carries out the actions a reply asks for.
@MainActor
enum ActionRunner {
    static func progress(for tag: ActionTag) -> String {
        switch tag.kind {
        case .openApp: "Opening \(tag.value)…"
        case .quitApp: "Quitting \(tag.value)…"
        case .openURL: "Opening \(ActionRules.addressAndBrowser(from: tag.value).address)…"
        case .findFile: "Searching for \(tag.value)…"
        case .typeText: "Typing…"
        case .pressKey: "Pressing \(tag.value)…"
        case .copy: "Copying…"
        case .paste: "Pasting…"
        case .plan, .confirm, .remember, .forget: ""
        }
    }

    static func run(_ tag: ActionTag) async -> ActionResult {
        switch tag.kind {
        case .openApp: await openApp(tag.value)
        case .quitApp: quitApp(tag.value)
        case .openURL: await openURL(tag.value)
        case .findFile: await findFile(tag.value)
        case .typeText: await type(tag.value)
        case .pressKey: await press(tag.value)
        case .copy: copy(tag.value)
        case .paste: await paste(tag.value)
        // The coordinator handles these, since they don't touch the Mac.
        case .plan, .confirm, .remember, .forget: ActionResult(summary: "")
        }
    }

    // MARK: - Clicks

    /// Apps where a click could weaken the Mac's security or approve something, so the user always does those.
    private static let protectedApps: Set<String> = [
        "com.apple.systempreferences",
        "com.apple.SecurityAgent",
        "com.apple.UserNotificationCenter",
    ]

    /// Clicks at a point in AppKit coordinates, then puts the cursor back where it was.
    static func click(at point: CGPoint, label: String?) async -> ActionResult {
        let name = label ?? "that"
        if let missing = missingAccessibility() { return missing }
        guard let primary = NSScreen.screens.first else {
            return ActionResult(summary: "Couldn't click \(name)", failure: "I couldn't click that.")
        }
        let location = Geometry.quartzPoint(appKit: point, primaryHeight: primary.frame.height)

        if let owner = frontWindow(at: location) {
            if protectedApps.contains(owner.app.bundleIdentifier ?? "") {
                let appName = owner.app.localizedName ?? "that window"
                return ActionResult(
                    summary: "Left \(appName) to you",
                    failure: "I don't click in \(appName), so that one's yours to do."
                )
            }
            // A window in the background may only come forward on its first click, so bring it forward now.
            if owner.isNormalWindow, !owner.app.isActive {
                owner.app.activate()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        guard !Task.isCancelled else { return ActionResult(summary: "") }

        let original = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: .left) else { return }
            event.flags = []
            if type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: 1) }
            event.post(tap: .cghidEventTap)
        }
        // Moving first gives lists and buttons a chance to react to the hover, as they would for a person.
        post(.mouseMoved)
        try? await Task.sleep(nanoseconds: 80_000_000)
        post(.leftMouseDown)
        try? await Task.sleep(nanoseconds: 50_000_000)
        post(.leftMouseUp)
        if let original { CGWarpMouseCursorPosition(original) }
        return ActionResult(summary: "Clicked \(name)")
    }

    private static func missingAccessibility() -> ActionResult? {
        guard !Permissions.accessibility else { return nil }
        Permissions.requestAccessibility()
        return ActionResult(
            summary: "Needs Accessibility access",
            failure: "I need Accessibility access before I can use your mouse and keyboard. Turn on Jarvis in System Settings, then ask me again."
        )
    }

    /// The frontmost window under a point in mouse-event coordinates, leaving out Jarvis's own click-through windows.
    private static func frontWindow(at location: CGPoint) -> (app: NSRunningApplication, isNormalWindow: Bool)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(location),
                  let app = NSRunningApplication(processIdentifier: pid)
            else { continue }
            return (app, window[kCGWindowLayer as String] as? Int == 0)
        }
        return nil
    }

    // MARK: - Keyboard

    /// Typing here could run commands or unlock things, so the user always does it themselves.
    private static let noKeyboardApps: Set<String> = protectedApps.union([
        "com.apple.keychainaccess",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "co.zeit.hyper",
    ])
    /// Gives the app time to react to a click or a shortcut before the next key arrives.
    private static let keyboardSettle: UInt64 = 150_000_000
    private static let betweenCharacters: UInt64 = 8_000_000

    /// Why the keyboard can't be used right now. It's checked again during typing, because focus can move.
    private static func keyboardRefusal() -> ActionResult? {
        // macOS turns this on while a password field has focus.
        if IsSecureEventInputEnabled() {
            return ActionResult(summary: "Left that field to you", failure: "That looks like a password field, so that one's yours to type.")
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ActionResult(summary: "Didn't type", failure: "I couldn't tell which app would get the keys, so I stopped.")
        }
        // Jarvis's own Settings window holds the API key.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier
            || noKeyboardApps.contains(app.bundleIdentifier ?? "") {
            let name = app.localizedName ?? "that app"
            return ActionResult(summary: "Left \(name) to you", failure: "I don't type in \(name), so that one's yours to do.")
        }
        return nil
    }

    private static func type(_ text: String) async -> ActionResult {
        if let missing = missingAccessibility() { return missing }
        guard let text = ActionRules.typableText(from: text) else {
            return ActionResult(summary: "Nothing to type")
        }
        try? await Task.sleep(nanoseconds: keyboardSettle)
        let source = CGEventSource(stateID: .hidSystemState)
        for character in text {
            guard !Task.isCancelled else { return ActionResult(summary: "") }
            if let refusal = keyboardRefusal() { return refusal }
            let units = Array(String(character).utf16)
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
                // Clearing the flags means a key the user is holding can't turn a letter into a shortcut.
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: betweenCharacters)
        }
        return ActionResult(summary: "Typed \"\(text.prefix(40))\"")
    }

    private static func press(_ text: String) async -> ActionResult {
        if let missing = missingAccessibility() { return missing }
        guard let combo = KeyCombo.parse(text) else {
            return ActionResult(summary: "Didn't press \(text)", failure: "I can't press \(text) for you, so that one's yours to do.")
        }
        try? await Task.sleep(nanoseconds: keyboardSettle)
        guard !Task.isCancelled else { return ActionResult(summary: "") }
        if let refusal = keyboardRefusal() { return refusal }

        var flags: CGEventFlags = []
        if combo.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if combo.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if combo.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if combo.modifiers.contains(.control) { flags.insert(.maskControl) }

        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: isDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        return ActionResult(summary: "Pressed \(text)")
    }

    // MARK: - Clipboard

    private static func copy(_ text: String) -> ActionResult {
        setClipboard(text)
        return ActionResult(summary: "Copied to the clipboard")
    }

    private static func setClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The clipboard's text, unless the app that copied it marked it as a secret, as password managers do.
    static func clipboardText() -> String? {
        let board = NSPasteboard.general
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        guard board.types?.contains(concealed) != true else { return nil }
        return ContextRules.limited(board.string(forType: .string))
    }

    private static func paste(_ text: String) async -> ActionResult {
        if let missing = missingAccessibility() { return missing }
        if let refusal = keyboardRefusal() { return refusal }
        setClipboard(text)
        try? await Task.sleep(nanoseconds: keyboardSettle)
        guard !Task.isCancelled else { return ActionResult(summary: "") }
        // Focus can move during the wait.
        if let refusal = keyboardRefusal() { return refusal }
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: isDown) else { continue }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
        return ActionResult(summary: "Pasted \"\(text.prefix(40))\"")
    }

    // MARK: - Apps

    private static func openApp(_ query: String) async -> ActionResult {
        guard let app = findApp(query) else {
            return ActionResult(
                summary: "Couldn't find \(query)",
                failure: "I couldn't find an app called \(query) on this Mac.",
                retryable: true
            )
        }
        let name = app.deletingPathExtension().lastPathComponent
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            return ActionResult(summary: "Opened \(name)")
        } catch {
            return ActionResult(summary: "Couldn't open \(name)", failure: "\(name) wouldn't open.", retryable: true)
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
            return ActionResult(summary: "\(query) isn't running", failure: "\(query) isn't running.", retryable: true)
        }
        // A normal quit, so the app can still ask about unsaved work.
        app.terminate()
        return ActionResult(summary: "Asked \(match) to quit")
    }

    // MARK: - Web

    private static func openURL(_ text: String) async -> ActionResult {
        let couldNotOpen = ActionResult(summary: "Couldn't open that address", failure: "I couldn't open that address.", retryable: true)
        let (address, browser) = ActionRules.addressAndBrowser(from: text)
        guard let url = ActionRules.webURL(from: address) else { return couldNotOpen }
        guard let browser else {
            return NSWorkspace.shared.open(url) ? ActionResult(summary: "Opened \(url.host ?? address)") : couldNotOpen
        }

        guard let app = findApp(browser), opensWebPages(app) else {
            return ActionResult(summary: "Couldn't find \(browser)", failure: "I couldn't find a browser called \(browser) on this Mac.", retryable: true)
        }
        let name = app.deletingPathExtension().lastPathComponent
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
            return ActionResult(summary: "Opened \(url.host ?? address) in \(name)")
        } catch {
            return ActionResult(summary: "Couldn't open \(name)", failure: "\(name) wouldn't open that address.", retryable: true)
        }
    }

    /// A close name match could be any app, and a web address should only ever go to a browser.
    private static func opensWebPages(_ app: URL) -> Bool {
        guard let sample = URL(string: "https://example.com") else { return false }
        return NSWorkspace.shared.urlsForApplications(toOpen: sample)
            .contains { $0.resolvingSymlinksInPath().path == app.resolvingSymlinksInPath().path }
    }

    // MARK: - Files

    /// Shows the best match in Finder without opening it, so nothing runs.
    private static func findFile(_ query: String) async -> ActionResult {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let found = await Task.detached { spotlight(["-onlyin", home, "-name", query]) }.value
        let usable = found.filter { !$0.contains("/Library/") && !$0.contains("/.") }
        guard let path = usable.first else {
            return ActionResult(summary: "Couldn't find \(query)", failure: "I couldn't find a file matching \(query).", retryable: true)
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
