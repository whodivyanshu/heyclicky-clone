import Foundation
import JarvisCore

/// JarvisCore behind one C function, so the Windows app shares its rules instead of keeping a second copy.
///
/// Each call takes a method name and a JSON object, and returns `{"ok": value}` or `{"error": "message"}`.
/// The returned string belongs to the caller, who gives it back to `jarvis_free`.
///
/// Screen coordinates here are Windows ones: physical pixels with y running down.
@_cdecl("jarvis_call")
public func jarvis_call(_ method: UnsafePointer<CChar>, _ params: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
    copyToC(Bridge.respond(method: String(cString: method), json: String(cString: params)))
}

@_cdecl("jarvis_free")
public func jarvis_free(_ text: UnsafeMutablePointer<CChar>?) {
    text?.deallocate()
}

/// Allocated here and freed by `jarvis_free`, so the two sides never share a C runtime's allocator.
private func copyToC(_ text: String) -> UnsafeMutablePointer<CChar> {
    let bytes = Array(text.utf8CString)
    let copy = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
    copy.initialize(from: bytes, count: bytes.count)
    return copy
}

struct BridgeError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Reads one call's parameters. A missing required value is an error, never a silent default.
struct Params {
    let values: [String: Any]

    func optionalString(_ name: String) -> String? { values[name] as? String }
    func string(_ name: String) throws -> String {
        guard let value = values[name] as? String else { throw BridgeError("Missing text: \(name)") }
        return value
    }
    func strings(_ name: String) -> [String] { values[name] as? [String] ?? [] }
    func bool(_ name: String) -> Bool { values[name] as? Bool ?? false }
    func optionalDouble(_ name: String) -> Double? { (values[name] as? NSNumber)?.doubleValue }
    func double(_ name: String) throws -> Double {
        guard let value = optionalDouble(name) else { throw BridgeError("Missing number: \(name)") }
        return value
    }
    func int(_ name: String) throws -> Int { Int(try double(name)) }
    func object(_ name: String) throws -> Params {
        guard let value = values[name] as? [String: Any] else { throw BridgeError("Missing object: \(name)") }
        return Params(values: value)
    }
    func objects(_ name: String) -> [Params] {
        (values[name] as? [[String: Any]] ?? []).map(Params.init)
    }
    func platform() -> Platform { .windows }
}

enum Bridge {
    private static let lock = NSLock()
    private static var nextHandle = 1
    private static var parsers: [Int: ResponseParser] = [:]
    private static var sessions: [Int: ControlSession] = [:]
    private static var guides: [Int: GuideSession] = [:]
    private static var watchers: [Int: ScreenWatchRules] = [:]

    static func respond(method: String, json: String) -> String {
        do {
            let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            guard let object else { throw BridgeError("The parameters must be a JSON object") }
            let result = try locked { try call(method, Params(values: object)) }
            return encode(["ok": result ?? NSNull()])
        } catch let error as BridgeError {
            return encode(["error": error.message])
        } catch {
            return encode(["error": error.localizedDescription])
        }
    }

    private static func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func encode(_ object: [String: Any]) -> String {
        // Checked first, because encoding an invalid value raises an exception Swift can't catch, which would take the app down.
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else {
            return #"{"error":"The result couldn't be encoded"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func handle() -> Int {
        defer { nextHandle += 1 }
        return nextHandle
    }

    // MARK: - Dispatch

    private static func call(_ method: String, _ p: Params) throws -> Any? {
        switch method {
        // Reading replies
        case "parser.new":
            let id = handle()
            parsers[id] = ResponseParser()
            return id
        case "parser.feed":
            let id = try p.int("id")
            guard var parser = parsers[id] else { throw BridgeError("No such parser") }
            let beats = parser.feed(try p.string("chunk"))
            parsers[id] = parser
            return beats.map(encode)
        case "parser.finish":
            let id = try p.int("id")
            guard var parser = parsers.removeValue(forKey: id) else { throw BridgeError("No such parser") }
            return parser.finish().map(encode)
        case "parser.free":
            parsers[try p.int("id")] = nil
            return nil
        case "reply.spokenText":
            return ResponseParser.spokenText(of: try p.string("reply"))

        // Actions
        case "action.info":
            guard let kind = ActionKind(rawValue: try p.string("kind")) else { throw BridgeError("Unknown action") }
            return [
                "usesKeyboard": kind.usesKeyboard, "isLookup": kind.isLookup, "isNative": kind.isNative,
                "changesScreen": kind.changesScreen, "canFinishRequest": kind.canFinishRequest,
            ]
        case "app.best":
            return AppMatcher.best(for: try p.string("query"), among: p.strings("names"))
        case "url.web":
            return ActionRules.webURL(from: try p.string("text"))?.absoluteString
        case "url.split":
            let parts = ActionRules.addressAndBrowser(from: try p.string("text"))
            return ["address": parts.address, "browser": parts.browser ?? NSNull()] as [String: Any]
        case "text.typable":
            return ActionRules.typableText(from: try p.string("text"))
        case "key.parse":
            guard let press = KeyCombo.windowsPress(try p.string("text")) else { return nil }
            return ["key": press.key, "control": press.control, "shift": press.shift, "alt": press.alt] as [String: Any]
        case "quick.action":
            let tag = QuickCommand.action(
                for: try p.string("transcript"),
                installedApps: { p.strings("installed") },
                runningApps: { p.strings("running") }
            )
            return tag.map(encode)
        case "quick.confirmation":
            return QuickCommand.confirmation(for: try actionTag(try p.object("tag")), hindi: p.bool("hindi"))

        // Safety
        case "risk.label":
            return RiskRules.riskyLabel(in: p.strings("labels"))
        case "risk.key":
            return RiskRules.keyNeedsConfirmation(try p.string("text"), context: try keyContext(try p.object("context")), platform: .windows)
        case "risk.terminalPane":
            return RiskRules.isTerminalPane(try keyContext(try p.object("context")), platform: .windows)
        case "policy.permits":
            let policy = AppAccessPolicy(onlyAllowed: p.bool("onlyAllowed"), allowed: p.strings("allowed"), blocked: p.strings("blocked"))
            return policy.permits(appName: try p.string("app"))
        case "windows.refusesClick":
            return WindowsAppRules.refusesClick(process: try p.string("process"), windowTitle: try p.string("title"))
        case "windows.refusesKeyboard":
            return WindowsAppRules.refusesKeyboard(process: try p.string("process"), windowTitle: try p.string("title"))
        case "confirm.decision":
            return ConfirmationRules.decision(from: try p.string("transcript"))

        // Screens
        case "screen.globalPoint":
            let point = try screenMap(p).globalPoint(imageX: try p.double("x"), imageY: try p.double("y"))
            // Double, because CGFloat isn't a JSON number on Windows.
            return ["x": Double(point.x), "y": Double(-point.y)]
        case "screen.imagePoint":
            let point = try screenMap(p).imagePoint(global: CGPoint(x: try p.double("x"), y: -(try p.double("y"))))
            return ["x": Double(point.x), "y": Double(point.y)]
        case "screen.fitted":
            let size = Geometry.fitted(width: try p.int("width"), height: try p.int("height"), maxLongEdge: try p.int("maxLongEdge"))
            return ["width": size.width, "height": size.height]
        case "screen.looksSame":
            return ScreenRules.looksSame(bytes(p.values["a"]), bytes(p.values["b"]))
        case "control.snap":
            return encode(ControlMatcher.snap(try pointTag(try p.object("tag")), to: try p.objects("controls").map(screenControl)))
        case "control.clean":
            return ScreenControl(role: "", label: try p.string("label"), x: 0, y: 0, width: 0, height: 0, screen: 1).label

        // A job Jarvis works through by itself
        case "session.new":
            let id = handle()
            sessions[id] = ControlSession(task: try p.string("task"))
            return id
        case "session.free":
            sessions[try p.int("id")] = nil
            return nil
        case "session.record":
            try updateSession(p) { $0.record(try p.string("summary")) }
            return nil
        case "session.setPlan":
            try updateSession(p) { $0.setPlan(try p.string("plan")) }
            return nil
        case "session.recordFailure":
            return try updateSession(p) { $0.recordFailure(try p.string("reason")) }
        case "session.advance":
            return try updateSession(p) { $0.advance() }
        case "session.needsAnotherLook":
            return try updateSession(p) { $0.needsAnotherLook(ranClickOrKeys: p.bool("ranClickOrKeys"), madePlan: p.bool("madePlan")) }
        case "session.followUp":
            return try updateSession(p) { $0.followUpGuidance() }

        // Walkthroughs
        case "guide.new":
            let id = handle()
            guides[id] = GuideSession(task: try p.string("task"))
            return id
        case "guide.free":
            guides[try p.int("id")] = nil
            return nil
        case "guide.setTarget":
            let tag = try pointTag(try p.object("tag"))
            return try updateGuide(p) { $0.setTarget(tag) }
        case "guide.complete":
            return try updateGuide(p) { $0.completeCurrent() }
        case "guide.current":
            return try updateGuide(p) { $0.current.map(encode) }
        case "guide.isHit":
            let click = CGPoint(x: try p.double("x"), y: -(try p.double("y")))
            let screen = try screenMap(p)
            return try updateGuide(p) { $0.isHit(click: click, on: screen) }
        case "guide.followUp":
            return try updateGuide(p) { $0.followUpGuidance() }

        // Prompts
        case "prompt.system":
            return Prompt.system(
                canControlMac: p.bool("canControl"),
                hindi: p.bool("hindi"),
                memories: p.strings("memories"),
                shortcuts: [],
                native: p.bool("native"),
                screenMemory: p.bool("screenMemory"),
                teachingNotes: p.optionalString("teachingNotes"),
                platform: .windows
            )
        case "prompt.user":
            var cursor: (screen: Int, x: Int, y: Int)?
            if let value = p.values["cursor"] as? [String: Any] {
                let c = Params(values: value)
                cursor = (try c.int("screen"), try c.int("x"), try c.int("y"))
            }
            return Prompt.userMessage(
                transcript: try p.string("transcript"),
                guidance: p.optionalString("guidance"),
                screens: try p.objects("screens").map {
                    Prompt.ScreenInfo(index: try $0.int("index"), pixelWidth: try $0.int("width"), pixelHeight: try $0.int("height"))
                },
                cursor: cursor,
                frontmostApp: p.optionalString("frontmostApp"),
                selection: p.optionalString("selection"),
                clipboard: p.optionalString("clipboard"),
                controls: try p.objects("controls").map(screenControl),
                now: p.optionalString("now")
            )
        case "context.mentionsClipboard":
            return ContextRules.mentionsClipboard(try p.string("transcript"))
        case "context.limited":
            return ContextRules.limited(p.optionalString("text"))
        case "lookup.guidance":
            return NativeRules.lookupGuidance(task: try p.string("task"), results: p.strings("results"))
        case "teaching.notes":
            let packs = p.objects("packs").compactMap { pack -> TeachingPack? in
                guard let name = pack.optionalString("name"), let notes = pack.optionalString("notes") else { return nil }
                return TeachingPack(name: name, apps: pack.strings("apps"), notes: notes)
            } + TeachingPack.builtIn
            return TeachingPack.notes(forApp: p.optionalString("app"), transcript: try p.string("transcript"), packs: packs)
                .map(TeachingPack.windowsWording)
        case "teaching.parse":
            guard let pack = TeachingPack.parse(fileName: try p.string("fileName"), text: try p.string("text")) else { return nil }
            return encode(pack)
        case "teaching.builtIn":
            return TeachingPack.builtIn.map(encode)

        // Providers
        case "gemini.body":
            return String(decoding: try GeminiWire.requestBody(try aiRequest(p)), as: UTF8.self)
        case "gemini.text":
            return try GeminiWire.text(fromSSELine: try p.string("line"))
        case "gemini.error":
            return GeminiWire.errorMessage(fromBody: try p.string("body"))
        case "ollama.body":
            return String(decoding: try OllamaWire.requestBody(try aiRequest(p), model: try p.string("model")), as: UTF8.self)
        case "ollama.text":
            return try OllamaWire.text(fromLine: try p.string("line"))
        case "ollama.error":
            return OllamaWire.errorMessage(fromBody: try p.string("body"))
        case "ollama.models":
            return OllamaWire.modelNames(fromTags: Data(try p.string("body").utf8))
        case "claude.input":
            return String(decoding: try ClaudeCodeWire.inputLine(try aiRequest(p)), as: UTF8.self)
        case "claude.arguments":
            return ClaudeCodeWire.arguments(model: try p.string("model"), system: try p.string("system"))
        case "claude.event":
            switch ClaudeCodeWire.event(fromLine: try p.string("line")) {
            case .text(let text): return ["type": "text", "text": text]
            case .result(let text, let isError): return ["type": "result", "text": text, "isError": isError] as [String: Any]
            case nil: return nil
            }
        case "voice.body":
            return String(decoding: try GeminiVoiceWire.requestBody(
                text: try p.string("text"),
                voice: p.optionalString("voice") ?? GeminiVoiceWire.defaultVoice,
                model: p.optionalString("model") ?? GeminiVoiceWire.defaultModel,
                style: p.optionalString("style") ?? GeminiVoiceWire.defaultStyle
            ), as: UTF8.self)
        case "voice.audio":
            return try GeminiVoiceWire.audio(fromSSELine: try p.string("line"))?.base64EncodedString()
        case "voice.catalog":
            return [
                "endpoint": GeminiVoiceWire.endpoint,
                "defaultModel": GeminiVoiceWire.defaultModel,
                "defaultVoice": GeminiVoiceWire.defaultVoice,
                "defaultStyle": GeminiVoiceWire.defaultStyle,
                "hindiVoice": GeminiVoiceWire.hindiAssistantVoice,
                "hindiStyle": GeminiVoiceWire.hindiAssistantStyle,
                "sampleRate": GeminiVoiceWire.sampleRate,
                "voices": GeminiVoiceWire.voices.map { ["name": $0.name, "style": $0.style] },
            ] as [String: Any]

        // Memory, screen memory and listening
        case "memory.add":
            var book = MemoryBook(facts: p.strings("facts"))
            let saved = book.add(try p.string("text"))
            return ["facts": book.facts, "saved": saved ?? NSNull()] as [String: Any]
        case "memory.forget":
            var book = MemoryBook(facts: p.strings("facts"))
            let removed = book.forget(matching: try p.string("query"))
            return ["facts": book.facts, "removed": removed] as [String: Any]
        case "screenMemory.isPrivate":
            return ScreenMemoryRules.isPrivate(appName: try p.string("app"), windowTitle: try p.string("title"))
        case "screenMemory.redacted":
            return ScreenMemoryRules.redacted(try p.string("text"))
        case "screenMemory.isWorthSaving":
            return ScreenMemoryRules.isWorthSaving(try p.string("text"), after: p.optionalString("previous"))
        case "screenMemory.matchQuery":
            return ScreenMemoryRules.matchQuery(try p.string("query"))
        case "watch.new":
            let id = handle()
            watchers[id] = ScreenWatchRules()
            return id
        case "watch.offer":
            let id = try p.int("id")
            guard var rules = watchers[id] else { throw BridgeError("No such watcher") }
            let offer = rules.offer(forScreenText: try p.string("text"), now: Date())
            watchers[id] = rules
            return offer
        case "wake.command":
            return WakeWord.command(in: try p.string("transcript"))
        case "followUp.ends":
            return FollowUpRules.endsConversation(try p.string("transcript"))
        case "dictation.withoutFillers":
            return DictationRules.withoutFillers(try p.string("text"))
        case "dictation.cleanupSystem":
            return DictationRules.cleanupSystem
        case "dictation.accepted":
            return DictationRules.accepted(cleaned: try p.string("cleaned"), original: try p.string("original"))
        case "barge.interruption":
            switch BargeInRules.interruption(heard: try p.string("heard"), speaking: try p.string("speaking")) {
            case .stop: return ["type": "stop"]
            case .request(let start):
                return ["type": "request", "text": BargeInRules.request(heard: try p.string("heard"), startingAt: start)]
            case nil: return nil
            }

        // Meetings
        case "meeting.command":
            switch MeetingRules.command(in: try p.string("transcript")) {
            case .start: return "start"
            case .stop: return "stop"
            case nil: return nil
            }
        case "meeting.summaryRequest":
            let request = MeetingRules.summaryRequest(transcript: try p.string("transcript"), hindi: p.bool("hindi"))
            return ["system": request.system, "userText": request.userText]
        case "meeting.actionItems":
            return MeetingRules.actionItems(in: try p.string("summary"))

        // Calendar, reminders and mail
        case "native.newEvent":
            guard let event = NativeRules.newEvent(from: try p.string("text")) else { return nil }
            return ["title": event.title, "start": event.start.timeIntervalSince1970, "minutes": event.minutes] as [String: Any]
        case "native.newReminder":
            guard let reminder = NativeRules.newReminder(from: try p.string("text")) else { return nil }
            return ["title": reminder.title, "due": reminder.due?.timeIntervalSince1970 ?? NSNull()] as [String: Any]
        case "native.range":
            guard let range = NativeRules.range(from: try p.string("text")) else { return nil }
            return ["start": range.start.timeIntervalSince1970, "end": range.end.timeIntervalSince1970]
        case "native.mailURL":
            return NativeRules.mailDraft(from: try p.string("text"))?.url?.absoluteString

        // Routines. The book is kept by the app as this JSON, and only changed in here.
        case "routines.add":
            guard let routine = Routine.parse(try p.string("text")) else { return ["added": false, "book": try p.string("book")] }
            var book = try routineBook(p)
            let added = book.add(routine)
            return ["added": added, "name": routine.name, "book": try encodeBook(book)] as [String: Any]
        case "routines.removeNamed":
            var book = try routineBook(p)
            let removed = book.remove(named: try p.string("name"))
            return ["removed": removed?.name ?? NSNull(), "book": try encodeBook(book)] as [String: Any]
        case "routines.matching":
            return try routineBook(p).routine(matching: try p.string("transcript"))?.request
        case "routines.due":
            var book = try routineBook(p)
            let now = Date()
            let due = book.due(at: now)
            for routine in due { book.markRan(routine.id, at: now) }
            return ["requests": due.map(\.request), "book": try encodeBook(book)] as [String: Any]
        case "routines.list":
            return try routineBook(p).routines.map {
                ["id": $0.id.uuidString, "name": $0.name, "when": $0.trigger.summary, "request": $0.request]
            }
        case "routines.removeID":
            var book = try routineBook(p)
            guard let id = UUID(uuidString: try p.string("routineID")) else { throw BridgeError("Bad routine id") }
            book.remove(id: id)
            return try encodeBook(book)

        default:
            throw BridgeError("Unknown method: \(method)")
        }
    }

    // MARK: - Sessions

    private static func updateSession<T>(_ p: Params, _ body: (inout ControlSession) throws -> T) throws -> T {
        let id = try p.int("id")
        guard var session = sessions[id] else { throw BridgeError("No such session") }
        defer { sessions[id] = session }
        return try body(&session)
    }

    private static func updateGuide<T>(_ p: Params, _ body: (inout GuideSession) throws -> T) throws -> T {
        let id = try p.int("id")
        guard var guide = guides[id] else { throw BridgeError("No such walkthrough") }
        defer { guides[id] = guide }
        return try body(&guide)
    }

    // MARK: - Reading values

    private static func actionTag(_ p: Params) throws -> ActionTag {
        guard let kind = ActionKind(rawValue: try p.string("kind")) else { throw BridgeError("Unknown action") }
        return ActionTag(kind: kind, value: try p.string("value"))
    }

    private static func keyContext(_ p: Params) throws -> KeyContext {
        KeyContext(
            appName: p.optionalString("appName") ?? "",
            windowTitle: p.optionalString("windowTitle") ?? "",
            focusedRole: p.optionalString("focusedRole") ?? "",
            focusedLabel: p.optionalString("focusedLabel") ?? "",
            defaultButton: p.optionalString("defaultButton") ?? "",
            surroundingLabels: p.strings("surroundingLabels")
        )
    }

    private static func pointTag(_ p: Params) throws -> PointTag {
        PointTag(
            x: try p.double("x"),
            y: try p.double("y"),
            label: p.optionalString("label"),
            screen: p.optionalDouble("screen").map { Int($0) },
            radius: p.optionalDouble("radius")
        )
    }

    private static func screenControl(_ p: Params) throws -> ScreenControl {
        ScreenControl(
            role: try p.string("role"), label: try p.string("label"),
            x: try p.double("x"), y: try p.double("y"),
            width: try p.double("width"), height: try p.double("height"),
            screen: try p.int("screen")
        )
    }

    /// `frame` arrives in Windows coordinates. The core works with y running up, so y is negated on the way in
    /// and on the way out, which keeps one set of formulas and doesn't need the primary display's height.
    private static func screenMap(_ p: Params) throws -> ScreenMap {
        let frame = try p.object("screen")
        let x = try frame.double("x"), y = try frame.double("y")
        let width = try frame.double("width"), height = try frame.double("height")
        return ScreenMap(
            index: try frame.int("index"),
            frame: CGRect(x: x, y: -(y + height), width: width, height: height),
            imageSize: CGSize(width: try frame.double("imageWidth"), height: try frame.double("imageHeight"))
        )
    }

    private static func aiRequest(_ p: Params) throws -> AIRequest {
        AIRequest(
            system: try p.string("system"),
            history: p.objects("history").compactMap { turn in
                guard let user = turn.optionalString("user"), let assistant = turn.optionalString("assistant") else { return nil }
                return ChatTurn(user: user, assistant: assistant)
            },
            userText: try p.string("userText"),
            jpegImages: try p.strings("images").map {
                guard let data = Data(base64Encoded: $0) else { throw BridgeError("A screenshot wasn't valid base64") }
                return data
            }
        )
    }

    private static func bytes(_ value: Any?) -> [UInt8] {
        (value as? String).flatMap { Data(base64Encoded: $0) }.map(Array.init) ?? []
    }

    private static func routineBook(_ p: Params) throws -> RoutineBook {
        let text = p.optionalString("book") ?? ""
        guard !text.isEmpty else { return RoutineBook() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(RoutineBook.self, from: Data(text.utf8))
        } catch {
            throw BridgeError("The saved routines couldn't be read")
        }
    }

    private static func encodeBook(_ book: RoutineBook) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return String(decoding: try encoder.encode(book), as: UTF8.self)
    }

    // MARK: - Writing values

    private static func encode(_ tag: ActionTag) -> [String: Any] {
        ["kind": tag.kind.rawValue, "value": tag.value]
    }

    private static func encode(_ tag: PointTag) -> [String: Any] {
        [
            "x": tag.x, "y": tag.y,
            "label": tag.label ?? NSNull(),
            "screen": tag.screen ?? NSNull(),
            "radius": tag.radius ?? NSNull(),
        ]
    }

    private static func encode(_ beat: Beat) -> [String: Any] {
        switch beat {
        case .say(let text): ["type": "say", "text": text]
        case .point(let tag): ["type": "point", "tag": encode(tag)]
        case .target(let tag): ["type": "target", "tag": encode(tag)]
        case .click(let tag): ["type": "click", "tag": encode(tag)]
        case .action(let tag): ["type": "action", "tag": encode(tag)]
        case .next: ["type": "next"]
        case .done: ["type": "done"]
        }
    }

    private static func encode(_ pack: TeachingPack) -> [String: Any] {
        ["name": pack.name, "apps": pack.apps, "notes": pack.notes, "isBuiltIn": pack.isBuiltIn]
    }
}
