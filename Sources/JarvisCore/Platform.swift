import Foundation

/// Where Jarvis is running, for the rules and wording that differ. Everything defaults to `.mac`.
public enum Platform: String, Sendable {
    case mac, windows
}

/// Windows apps Jarvis leaves to the user. Names are process names, with or without `.exe`.
public enum WindowsAppRules {
    /// A click here could weaken the PC's security or approve something.
    private static let protectedProcesses: Set<String> = [
        "consent", "logonui", "credentialuibroker", "credwiz", "systemsettings", "securityhealthhost", "securityhealthsystray",
        "regedit", "taskmgr", "mmc", "msconfig", "lockapp", "windowsdefender", "msmpeng",
    ]
    /// Typing here could run commands, so it's also refused.
    private static let terminalProcesses: Set<String> = [
        "cmd", "powershell", "powershell_ise", "pwsh", "windowsterminal", "wt", "conhost", "openconsole",
        "wsl", "wslhost", "bash", "mintty", "alacritty", "wezterm-gui", "hyper", "tabby", "warp", "kitty", "ghostty", "putty",
    ]
    /// Settings and Windows Security are hosted by a shared process, so only the title tells them apart.
    private static let protectedHostedTitles = ["settings", "windows security"]
    /// File Explorer hosts the Run box, where typed text runs as a command.
    private static let shellProcess = "explorer"

    private static func normalized(_ process: String) -> String {
        let name = process.lowercased().trimmingCharacters(in: .whitespaces)
        return name.hasSuffix(".exe") ? String(name.dropLast(4)) : name
    }

    public static func refusesClick(process: String, windowTitle: String) -> Bool {
        let name = normalized(process)
        if protectedProcesses.contains(name) { return true }
        let title = windowTitle.lowercased().trimmingCharacters(in: .whitespaces)
        return name == "applicationframehost" && protectedHostedTitles.contains(title)
    }

    public static func refusesKeyboard(process: String, windowTitle: String) -> Bool {
        let name = normalized(process)
        if refusesClick(process: process, windowTitle: windowTitle) || terminalProcesses.contains(name) { return true }
        return name == shellProcess && windowTitle.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Run") == .orderedSame
    }
}

extension Prompt {
    /// Windows names for what the prompt describes. Tested to leave no Mac words behind.
    static func windowsWording(_ text: String) -> String {
        var result = text
        for (mac, windows) in [
            ("Finder", "File Explorer"),
            ("Dock", "taskbar"),
            ("System Settings", "Windows Settings"),
            ("cmd+shift+n", "ctrl+shift+n"),
            ("cmd+t", "ctrl+t"),
            ("Esc isn't available.", "Esc, Alt+F4, Ctrl+Q and the Windows key aren't available."),
        ] {
            result = result.replacingOccurrences(of: mac, with: windows)
        }
        return result.replacingOccurrences(of: #"\bMac\b"#, with: "PC", options: .regularExpression)
    }
}

extension TeachingPack {
    /// The built-in notes name Mac shortcuts, which are the same on Windows with Ctrl and Alt.
    public static func windowsWording(_ notes: String) -> String {
        notes.replacingOccurrences(of: "Option+Command+", with: "Ctrl+Alt+")
            .replacingOccurrences(of: "Command+", with: "Ctrl+")
            .replacingOccurrences(of: "Control+", with: "Ctrl+")
    }
}
