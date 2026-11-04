import Foundation

/// Notes that help Jarvis teach a particular app. They only shape walkthroughs, and the screenshot always wins.
public struct TeachingPack: Equatable, Identifiable, Sendable {
    public var name: String
    public var apps: [String]
    public var notes: String
    public var isBuiltIn: Bool
    public var id: String { name }

    public static let maxNotesLength = 3000

    public init(name: String, apps: [String], notes: String, isBuiltIn: Bool = false) {
        self.name = name
        self.apps = apps
        self.notes = String(notes.prefix(Self.maxNotesLength))
        self.isBuiltIn = isBuiltIn
    }

    /// A file of their own: a first line such as `apps: Figma, FigJam`, then notes in plain words.
    public static func parse(fileName: String, text: String) -> TeachingPack? {
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = lines.first, first.lowercased().hasPrefix("apps:"), lines.count == 2 else { return nil }
        let apps = first.dropFirst(5).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let notes = lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apps.isEmpty, !notes.isEmpty else { return nil }
        let name = fileName.hasSuffix(".md") ? String(fileName.dropLast(3)) : fileName
        return TeachingPack(name: name, apps: apps, notes: notes)
    }

    /// Stable basics only, because menus and buttons change between versions.
    public static let builtIn: [TeachingPack] = [
        TeachingPack(name: "Figma", apps: ["Figma", "FigJam"], notes: """
        Teach the idea behind each step as well as the click. Frames hold designs and can use auto layout, which Shift+A adds. Groups only bundle things together.
        Reusable parts are components, which Option+Command+K creates. Copies of a component are instances that update with it.
        Prefer auto layout and components over moving things by hand. Prototype links are made on the Prototype tab of the right panel.
        """, isBuiltIn: true),
        TeachingPack(name: "Xcode", apps: ["Xcode"], notes: """
        Command+R runs, Command+B builds, Command+U runs tests and Command+. stops. Command+Shift+O opens any file or symbol quickly.
        The navigators on the left switch with Command+1 to Command+9. Build errors appear in the Issue navigator, so go there first when something fails.
        Signing is set on the target's Signing & Capabilities tab. Explain what an error means before showing the fix.
        """, isBuiltIn: true),
        TeachingPack(name: "VS Code", apps: ["Visual Studio Code", "Code", "Cursor"], notes: """
        Command+Shift+P opens the Command Palette, which reaches nearly everything, so teach that first. Command+P opens a file by name.
        Control+` shows the terminal, Command+B toggles the sidebar and Command+Shift+F searches every file.
        Extensions are in the sidebar's Extensions view. Settings open with Command+comma.
        """, isBuiltIn: true),
        TeachingPack(name: "Excel", apps: ["Microsoft Excel"], notes: """
        Teach them to turn a range into a table with Command+T before anything else, because tables grow and filter by themselves.
        Formulas start with an equals sign. Explain cell references and when a dollar sign keeps one fixed. Pivot tables are on the Insert tab.
        Show the reason behind a formula, not only what to type, and let them type it themselves.
        """, isBuiltIn: true),
    ]

    private static let teachingWords = try! NSRegularExpression(
        pattern: #"\b(teach me|show me how|walk me through|how do i|how can i|how to|help me learn)\b"#,
        options: [.caseInsensitive]
    )
    private static let hindiTeachingWords = ["सिखाओ", "सिखाइए", "सिखा दो", "कैसे करूँ", "कैसे करते", "sikhao", "kaise karu"]

    /// Whether they want to learn, as opposed to having the job done or a quick answer.
    public static func wantsTeaching(_ transcript: String) -> Bool {
        if teachingWords.firstMatch(in: transcript, range: NSRange(transcript.startIndex..., in: transcript)) != nil { return true }
        let lowered = transcript.lowercased()
        return hindiTeachingWords.contains { lowered.range(of: $0, options: .literal) != nil }
    }

    /// The notes to use for this request, with their own pack coming before a built-in one.
    public static func notes(forApp app: String?, transcript: String, packs: [TeachingPack]) -> String? {
        guard let app, wantsTeaching(transcript) else { return nil }
        let wanted = AppMatcher.normalized(app)
        return packs.first { $0.apps.contains { AppMatcher.normalized($0) == wanted } }?.notes
    }
}
