using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Jarvis;

public sealed class CoreException(string message) : Exception(message);

public sealed record ChatTurn(string User, string Assistant);
public sealed record ActionTag(string Kind, string Value);
public sealed record PointTag(double X, double Y, string? Label, int? Screen, double? Radius);

/// <summary>One step of a reply, in the order it should happen.</summary>
public abstract record Beat
{
    public sealed record Say(string Text) : Beat;
    public sealed record Point(PointTag Tag) : Beat;
    public sealed record Target(PointTag Tag) : Beat;
    public sealed record Click(PointTag Tag) : Beat;
    public sealed record Act(ActionTag Tag) : Beat;
    public sealed record Next : Beat;
    public sealed record Done : Beat;
}

public sealed record ActionInfo(bool UsesKeyboard, bool IsLookup, bool IsNative, bool ChangesScreen, bool CanFinishRequest);
public sealed record KeyPress(string Key, bool Control, bool Shift, bool Alt);
public sealed record KeyContext(string AppName = "", string WindowTitle = "", string FocusedRole = "", string FocusedLabel = "", string DefaultButton = "", IReadOnlyList<string>? SurroundingLabels = null);
public sealed record ScreenControl(string Role, string Label, double X, double Y, double Width, double Height, int Screen);
public sealed record ScreenMap(int Index, double X, double Y, double Width, double Height, double ImageWidth, double ImageHeight);
public sealed record CursorInfo(int Screen, int X, int Y);
public sealed record AIRequest(string System, IReadOnlyList<ChatTurn> History, string UserText, IReadOnlyList<byte[]> Images)
{
    public AIRequest(string system, string userText) : this(system, Array.Empty<ChatTurn>(), userText, Array.Empty<byte[]>()) { }
}

/// <summary>
/// The rules shared with the Mac app, which live in Swift (JarvisCore) so there is only one copy.
/// Every call crosses as JSON. Screen coordinates are Windows ones: physical pixels with y running down.
/// </summary>
public static class Core
{
    [DllImport("JarvisBridge", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr jarvis_call(byte[] method, byte[] parameters);

    [DllImport("JarvisBridge", CallingConvention = CallingConvention.Cdecl)]
    private static extern void jarvis_free(IntPtr text);

    private static byte[] Utf8(string text) => Encoding.UTF8.GetBytes(text + "\0");

    /// <summary>The raw call. Errors from the core become exceptions, never a silent "no".</summary>
    public static JsonNode? Call(string method, JsonObject? parameters = null)
    {
        IntPtr result = jarvis_call(Utf8(method), Utf8((parameters ?? new JsonObject()).ToJsonString()));
        string json;
        try { json = Marshal.PtrToStringUTF8(result) ?? "{}"; }
        finally { jarvis_free(result); }
        var response = JsonNode.Parse(json) as JsonObject ?? throw new CoreException("The core sent back something unreadable.");
        if (response.TryGetPropertyValue("error", out var error) && error is not null)
            throw new CoreException(error.GetValue<string>());
        return response["ok"];
    }

    private static JsonObject O(params (string Key, JsonNode? Value)[] items)
    {
        var result = new JsonObject();
        foreach (var (key, value) in items) if (value is not null) result[key] = value;
        return result;
    }

    private static JsonArray A(IEnumerable<string> items) => new(items.Select(i => (JsonNode?)JsonValue.Create(i)).ToArray());
    private static string? S(JsonNode? node) => node?.GetValue<string>();
    private static bool B(JsonNode? node) => node?.GetValue<bool>() ?? false;
    private static List<string> L(JsonNode? node) => node is JsonArray a ? a.Select(i => i!.GetValue<string>()).ToList() : new();

    // Reading replies

    public static int ParserNew() => Call("parser.new")!.GetValue<int>();
    public static List<Beat> ParserFeed(int id, string chunk) => Beats(Call("parser.feed", O(("id", id), ("chunk", chunk))));
    public static List<Beat> ParserFinish(int id) => Beats(Call("parser.finish", O(("id", id))));
    public static void ParserFree(int id) => Call("parser.free", O(("id", id)));
    public static string SpokenText(string reply) => S(Call("reply.spokenText", O(("reply", reply)))) ?? "";

    private static List<Beat> Beats(JsonNode? node)
    {
        var beats = new List<Beat>();
        if (node is not JsonArray list) return beats;
        foreach (var item in list)
        {
            switch (S(item!["type"]))
            {
                case "say": beats.Add(new Beat.Say(S(item["text"]) ?? "")); break;
                case "point": beats.Add(new Beat.Point(ReadPoint(item["tag"]!))); break;
                case "target": beats.Add(new Beat.Target(ReadPoint(item["tag"]!))); break;
                case "click": beats.Add(new Beat.Click(ReadPoint(item["tag"]!))); break;
                case "action": beats.Add(new Beat.Act(ReadAction(item["tag"]!))); break;
                case "next": beats.Add(new Beat.Next()); break;
                case "done": beats.Add(new Beat.Done()); break;
            }
        }
        return beats;
    }

    private static PointTag ReadPoint(JsonNode node) => new(
        node["x"]!.GetValue<double>(), node["y"]!.GetValue<double>(),
        S(node["label"]), node["screen"]?.GetValue<int>(), node["radius"]?.GetValue<double>());

    private static ActionTag ReadAction(JsonNode node) => new(S(node["kind"])!, S(node["value"]) ?? "");

    private static JsonObject Write(PointTag tag) =>
        O(("x", tag.X), ("y", tag.Y), ("label", tag.Label), ("screen", tag.Screen), ("radius", tag.Radius));

    private static JsonObject Write(ScreenMap map) => O(
        ("index", map.Index), ("x", map.X), ("y", map.Y), ("width", map.Width), ("height", map.Height),
        ("imageWidth", map.ImageWidth), ("imageHeight", map.ImageHeight));

    private static JsonObject Write(ScreenControl c) => O(
        ("role", c.Role), ("label", c.Label), ("x", c.X), ("y", c.Y), ("width", c.Width), ("height", c.Height), ("screen", c.Screen));

    private static JsonObject Write(KeyContext c) => O(
        ("appName", c.AppName), ("windowTitle", c.WindowTitle), ("focusedRole", c.FocusedRole), ("focusedLabel", c.FocusedLabel),
        ("defaultButton", c.DefaultButton), ("surroundingLabels", A(c.SurroundingLabels ?? Array.Empty<string>())));

    // Actions

    private static readonly Dictionary<string, ActionInfo> ActionCache = new();
    public static ActionInfo Info(string kind)
    {
        if (ActionCache.TryGetValue(kind, out var known)) return known;
        var n = Call("action.info", O(("kind", kind)))!;
        return ActionCache[kind] = new ActionInfo(B(n["usesKeyboard"]), B(n["isLookup"]), B(n["isNative"]), B(n["changesScreen"]), B(n["canFinishRequest"]));
    }

    public static string? BestApp(string query, IEnumerable<string> names) => S(Call("app.best", O(("query", query), ("names", A(names)))));
    public static string? WebUrl(string text) => S(Call("url.web", O(("text", text))));
    public static (string Address, string? Browser) SplitUrl(string text)
    {
        var n = Call("url.split", O(("text", text)))!;
        return (S(n["address"]) ?? "", S(n["browser"]));
    }
    public static string? TypableText(string text) => S(Call("text.typable", O(("text", text))));

    public static KeyPress? ParseKey(string text)
    {
        var n = Call("key.parse", O(("text", text)));
        return n is null ? null : new KeyPress(S(n["key"])!, B(n["control"]), B(n["shift"]), B(n["alt"]));
    }

    /// <summary>The lists are only read if this sentence uses them, because finding apps takes a moment.</summary>
    public static ActionTag? QuickAction(string transcript, Func<IEnumerable<string>> installed, Func<IEnumerable<string>> running)
    {
        var needs = Call("quick.needs", O(("transcript", transcript)))!;
        var installedNames = B(needs["installed"]) ? installed() : Array.Empty<string>();
        var runningNames = B(needs["running"]) ? running() : Array.Empty<string>();
        var n = Call("quick.action", O(("transcript", transcript), ("installed", A(installedNames)), ("running", A(runningNames))));
        return n is null ? null : ReadAction(n);
    }

    public static string QuickConfirmation(ActionTag tag, bool hindi) =>
        S(Call("quick.confirmation", O(("tag", O(("kind", tag.Kind), ("value", tag.Value))), ("hindi", hindi)))) ?? "";

    // Safety

    public static string? RiskyLabel(IEnumerable<string> labels) => S(Call("risk.label", O(("labels", A(labels)))));
    public static bool KeyNeedsConfirmation(string text, KeyContext context) => B(Call("risk.key", O(("text", text), ("context", Write(context)))));
    public static bool IsTerminalPane(KeyContext context) => B(Call("risk.terminalPane", O(("context", Write(context)))));
    public static bool RefusesClick(string process, string title) => B(Call("windows.refusesClick", O(("process", process), ("title", title))));
    public static bool RefusesKeyboard(string process, string title) => B(Call("windows.refusesKeyboard", O(("process", process), ("title", title))));
    public static bool? ConfirmationDecision(string transcript) => Call("confirm.decision", O(("transcript", transcript)))?.GetValue<bool>();
    public static bool PolicyPermits(AppPolicy policy, string app) => B(Call("policy.permits", O(
        ("onlyAllowed", policy.OnlyAllowed), ("allowed", A(policy.Allowed)), ("blocked", A(policy.Blocked)), ("app", app))));

    // Screens

    public static (double X, double Y) GlobalPoint(ScreenMap map, double x, double y)
    {
        var n = Call("screen.globalPoint", O(("screen", Write(map)), ("x", x), ("y", y)))!;
        return (n["x"]!.GetValue<double>(), n["y"]!.GetValue<double>());
    }

    public static (double X, double Y) ImagePoint(ScreenMap map, double x, double y)
    {
        var n = Call("screen.imagePoint", O(("screen", Write(map)), ("x", x), ("y", y)))!;
        return (n["x"]!.GetValue<double>(), n["y"]!.GetValue<double>());
    }

    public static (int Width, int Height) Fitted(int width, int height, int maxLongEdge)
    {
        var n = Call("screen.fitted", O(("width", width), ("height", height), ("maxLongEdge", maxLongEdge)))!;
        return (n["width"]!.GetValue<int>(), n["height"]!.GetValue<int>());
    }

    public static bool LooksSame(byte[] a, byte[] b) =>
        B(Call("screen.looksSame", O(("a", Convert.ToBase64String(a)), ("b", Convert.ToBase64String(b)))));

    public static PointTag Snap(PointTag tag, IEnumerable<ScreenControl> controls) =>
        ReadPoint(Call("control.snap", O(("tag", Write(tag)), ("controls", new JsonArray(controls.Select(c => (JsonNode?)Write(c)).ToArray()))))!);

    public static string CleanLabel(string label) => S(Call("control.clean", O(("label", label)))) ?? "";

    // Jobs and walkthroughs

    public static int SessionNew(string task) => Call("session.new", O(("task", task)))!.GetValue<int>();
    public static void SessionFree(int id) => Call("session.free", O(("id", id)));
    public static void SessionRecord(int id, string summary) => Call("session.record", O(("id", id), ("summary", summary)));
    public static void SessionSetPlan(int id, string plan) => Call("session.setPlan", O(("id", id), ("plan", plan)));
    public static bool SessionRecordFailure(int id, string reason) => B(Call("session.recordFailure", O(("id", id), ("reason", reason))));
    public static bool SessionAdvance(int id) => B(Call("session.advance", O(("id", id))));
    public static bool SessionNeedsAnotherLook(int id, bool ranClickOrKeys, bool madePlan) =>
        B(Call("session.needsAnotherLook", O(("id", id), ("ranClickOrKeys", ranClickOrKeys), ("madePlan", madePlan))));
    public static string SessionFollowUp(int id) => S(Call("session.followUp", O(("id", id)))) ?? "";

    public static int GuideNew(string task) => Call("guide.new", O(("task", task)))!.GetValue<int>();
    public static void GuideFree(int id) => Call("guide.free", O(("id", id)));
    public static bool GuideSetTarget(int id, PointTag tag) => B(Call("guide.setTarget", O(("id", id), ("tag", Write(tag)))));
    public static string GuideComplete(int id) => S(Call("guide.complete", O(("id", id)))) ?? "";
    public static PointTag? GuideCurrent(int id)
    {
        var n = Call("guide.current", O(("id", id)));
        return n is null ? null : ReadPoint(n);
    }
    public static bool GuideIsHit(int id, ScreenMap screen, double x, double y) =>
        B(Call("guide.isHit", O(("id", id), ("screen", Write(screen)), ("x", x), ("y", y))));
    public static string GuideFollowUp(int id) => S(Call("guide.followUp", O(("id", id)))) ?? "";

    // Prompts

    public static string SystemPrompt(bool canControl, bool hindi, IEnumerable<string> memories, bool screenMemory, string? teachingNotes) =>
        S(Call("prompt.system", O(("canControl", canControl), ("hindi", hindi), ("memories", A(memories)), ("native", true),
            ("screenMemory", screenMemory), ("teachingNotes", teachingNotes)))) ?? "";

    public static string UserMessage(string transcript, string? guidance, IEnumerable<ScreenMap> screens, CursorInfo? cursor, string? frontmostApp,
        string? selection, string? clipboard, IEnumerable<ScreenControl> controls, string? now)
    {
        var screenList = new JsonArray(screens.Select(s => (JsonNode?)O(("index", s.Index), ("width", (int)s.ImageWidth), ("height", (int)s.ImageHeight))).ToArray());
        return S(Call("prompt.user", O(
            ("transcript", transcript), ("guidance", guidance), ("screens", screenList),
            ("cursor", cursor is null ? null : O(("screen", cursor.Screen), ("x", cursor.X), ("y", cursor.Y))),
            ("frontmostApp", frontmostApp), ("selection", selection), ("clipboard", clipboard),
            ("controls", new JsonArray(controls.Select(c => (JsonNode?)Write(c)).ToArray())), ("now", now)))) ?? "";
    }

    public static bool MentionsClipboard(string transcript) => B(Call("context.mentionsClipboard", O(("transcript", transcript))));
    public static string? LimitedContext(string? text) => S(Call("context.limited", O(("text", text))));
    public static string LookupGuidance(string task, IEnumerable<string> results) => S(Call("lookup.guidance", O(("task", task), ("results", A(results))))) ?? "";

    public sealed record Pack(string Name, IReadOnlyList<string> Apps, string Notes, bool IsBuiltIn);

    public static string? TeachingNotes(string? app, string transcript, IEnumerable<Pack> custom) => S(Call("teaching.notes", O(
        ("app", app), ("transcript", transcript),
        ("packs", new JsonArray(custom.Select(p => (JsonNode?)O(("name", p.Name), ("apps", A(p.Apps)), ("notes", p.Notes))).ToArray())))));

    public static Pack? ParsePack(string fileName, string text)
    {
        var n = Call("teaching.parse", O(("fileName", fileName), ("text", text)));
        return n is null ? null : ReadPack(n);
    }

    public static List<Pack> BuiltInPacks() => (Call("teaching.builtIn") as JsonArray)?.Select(n => ReadPack(n!)).ToList() ?? new();
    private static Pack ReadPack(JsonNode n) => new(S(n["name"])!, L(n["apps"]), S(n["notes"]) ?? "", B(n["isBuiltIn"]));

    // Providers

    private static JsonObject Write(AIRequest r, params (string, JsonNode?)[] extra)
    {
        var result = O(("system", r.System), ("userText", r.UserText),
            ("history", new JsonArray(r.History.Select(t => (JsonNode?)O(("user", t.User), ("assistant", t.Assistant))).ToArray())),
            ("images", A(r.Images.Select(Convert.ToBase64String))));
        foreach (var (key, value) in extra) result[key] = value;
        return result;
    }

    public static string GeminiBody(AIRequest r) => S(Call("gemini.body", Write(r)))!;
    public static string? GeminiText(string line) => S(Call("gemini.text", O(("line", line))));
    public static string? GeminiError(string body) => S(Call("gemini.error", O(("body", body))));
    public static string OllamaBody(AIRequest r, string model) => S(Call("ollama.body", Write(r, ("model", model))))!;
    public static string? OllamaText(string line) => S(Call("ollama.text", O(("line", line))));
    public static string? OllamaError(string body) => S(Call("ollama.error", O(("body", body))));
    public static List<string> OllamaModels(string body) => L(Call("ollama.models", O(("body", body))));
    public static string ClaudeInput(AIRequest r) => S(Call("claude.input", Write(r)))!;
    public static List<string> ClaudeArguments(string model, string system) => L(Call("claude.arguments", O(("model", model), ("system", system))));

    public sealed record ClaudeEvent(string Type, string Text, bool IsError);
    public static ClaudeEvent? ClaudeEventFrom(string line)
    {
        var n = Call("claude.event", O(("line", line)));
        return n is null ? null : new ClaudeEvent(S(n["type"])!, S(n["text"]) ?? "", B(n["isError"]));
    }

    public static string VoiceBody(string text, string voice, string model, string style) =>
        S(Call("voice.body", O(("text", text), ("voice", voice), ("model", model), ("style", style))))!;
    public static byte[]? VoiceAudio(string line)
    {
        var encoded = S(Call("voice.audio", O(("line", line))));
        return encoded is null ? null : Convert.FromBase64String(encoded);
    }

    public sealed record VoiceCatalogInfo(string Endpoint, string DefaultModel, string DefaultVoice, string DefaultStyle, string HindiVoice, string HindiStyle, int SampleRate, IReadOnlyList<(string Name, string Style)> Voices);
    private static VoiceCatalogInfo? voiceCatalog;
    public static VoiceCatalogInfo VoiceCatalog
    {
        get
        {
            if (voiceCatalog is not null) return voiceCatalog;
            var n = Call("voice.catalog")!;
            return voiceCatalog = new VoiceCatalogInfo(S(n["endpoint"])!, S(n["defaultModel"])!, S(n["defaultVoice"])!, S(n["defaultStyle"])!, S(n["hindiVoice"])!, S(n["hindiStyle"])!,
                (int)n["sampleRate"]!.GetValue<double>(),
                ((JsonArray)n["voices"]!).Select(v => (S(v!["name"])!, S(v["style"])!)).ToList());
        }
    }

    // Memory, screen memory and listening

    public static (List<string> Facts, string? Saved) MemoryAdd(IEnumerable<string> facts, string text)
    {
        var n = Call("memory.add", O(("facts", A(facts)), ("text", text)))!;
        return (L(n["facts"]), S(n["saved"]));
    }

    public static (List<string> Facts, List<string> Removed) MemoryForget(IEnumerable<string> facts, string query)
    {
        var n = Call("memory.forget", O(("facts", A(facts)), ("query", query)))!;
        return (L(n["facts"]), L(n["removed"]));
    }

    public static bool ScreenIsPrivate(string app, string title) => B(Call("screenMemory.isPrivate", O(("app", app), ("title", title))));
    public static string Redacted(string text) => S(Call("screenMemory.redacted", O(("text", text)))) ?? "";
    public static bool IsWorthSaving(string text, string? previous) => B(Call("screenMemory.isWorthSaving", O(("text", text), ("previous", previous))));
    public static string? MatchQuery(string query) => S(Call("screenMemory.matchQuery", O(("query", query))));
    public static int WatchNew() => Call("watch.new")!.GetValue<int>();
    public static string? WatchOffer(int id, string text) => S(Call("watch.offer", O(("id", id), ("text", text))));
    public static string? WakeCommand(string transcript) => S(Call("wake.command", O(("transcript", transcript))));
    public static bool EndsConversation(string transcript) => B(Call("followUp.ends", O(("transcript", transcript))));
    public static string WithoutFillers(string text) => S(Call("dictation.withoutFillers", O(("text", text)))) ?? "";
    public static string CleanupSystem => S(Call("dictation.cleanupSystem")) ?? "";
    public static string AcceptedCleanup(string cleaned, string original) => S(Call("dictation.accepted", O(("cleaned", cleaned), ("original", original)))) ?? original;

    public sealed record Interruption(bool IsStop, int StartingAt, string Text);
    public static Interruption? BargeInterruption(string heard, string speaking)
    {
        var n = Call("barge.interruption", O(("heard", heard), ("speaking", speaking)));
        return n is null ? null : new Interruption(S(n["type"]) == "stop", n["startingAt"]?.GetValue<int>() ?? 0, S(n["text"]) ?? "");
    }
    public static string BargeRequest(string heard, int startingAt) => S(Call("barge.request", O(("heard", heard), ("startingAt", startingAt)))) ?? "";

    // Meetings

    public static string? MeetingCommand(string transcript) => S(Call("meeting.command", O(("transcript", transcript))));
    public static AIRequest MeetingSummaryRequest(string transcript, bool hindi)
    {
        var n = Call("meeting.summaryRequest", O(("transcript", transcript), ("hindi", hindi)))!;
        return new AIRequest(S(n["system"])!, S(n["userText"])!);
    }
    public static List<string> MeetingActionItems(string summary) => L(Call("meeting.actionItems", O(("summary", summary))));

    // Calendar, tasks and mail. Times cross as seconds since 1970.

    public sealed record NewEvent(string Title, DateTime Start, int Minutes);
    public sealed record NewReminder(string Title, DateTime? Due);

    private static DateTime FromUnix(double seconds) => DateTimeOffset.FromUnixTimeMilliseconds((long)(seconds * 1000)).LocalDateTime;

    public static NewEvent? ParseEvent(string text)
    {
        var n = Call("native.newEvent", O(("text", text)));
        return n is null ? null : new NewEvent(S(n["title"])!, FromUnix(n["start"]!.GetValue<double>()), n["minutes"]!.GetValue<int>());
    }

    public static NewReminder? ParseReminder(string text)
    {
        var n = Call("native.newReminder", O(("text", text)));
        return n is null ? null : new NewReminder(S(n["title"])!, n["due"] is null ? null : FromUnix(n["due"]!.GetValue<double>()));
    }

    public static (DateTime Start, DateTime End)? ParseRange(string text)
    {
        var n = Call("native.range", O(("text", text)));
        return n is null ? null : (FromUnix(n["start"]!.GetValue<double>()), FromUnix(n["end"]!.GetValue<double>()));
    }

    public static string? MailUrl(string text) => S(Call("native.mailURL", O(("text", text))));

    // Kokoro

    public sealed record Download(string Url, string Sha256, int Megabytes);
    public sealed record KokoroVoice(string Name, string Description, int Id);
    public sealed record KokoroInfo(Download Runtime, Download Model, string ModelFolder, IReadOnlyList<KokoroVoice> EnglishVoices, IReadOnlyList<KokoroVoice> HindiVoices, int DefaultEnglishVoice, int DefaultHindiVoice);
    private static KokoroInfo? kokoroCatalog;
    public static KokoroInfo KokoroCatalog
    {
        get
        {
            if (kokoroCatalog is not null) return kokoroCatalog;
            var n = Call("kokoro.catalog")!;
            static Download D(JsonNode d) => new(S(d["url"])!, S(d["sha256"])!, d["megabytes"]!.GetValue<int>());
            static List<KokoroVoice> V(JsonNode v) => ((JsonArray)v).Select(i => new KokoroVoice(S(i!["name"])!, S(i["description"])!, i["id"]!.GetValue<int>())).ToList();
            return kokoroCatalog = new KokoroInfo(D(n["runtime"]!), D(n["model"]!), S(n["modelFolder"])!, V(n["englishVoices"]!), V(n["hindiVoices"]!),
                n["defaultEnglishVoice"]!.GetValue<int>(), n["defaultHindiVoice"]!.GetValue<int>());
        }
    }

    public static (int Voice, string? Extra) KokoroVoiceFor(string text, int english, int hindi)
    {
        var n = Call("kokoro.voice", O(("text", text), ("english", english), ("hindi", hindi)))!;
        return (n["voice"]!.GetValue<int>(), S(n["extra"]));
    }

    // Routines. The book stays as the core's JSON, and only the core changes it.

    public sealed record RoutineRow(string Id, string Name, string When, string Request);

    public static (bool Added, string? Name, string Book) RoutineAdd(string book, string text)
    {
        var n = Call("routines.add", O(("book", book), ("text", text)))!;
        return (B(n["added"]), S(n["name"]), S(n["book"]) ?? book);
    }

    /// <summary>Returns a problem ("when" or "full"), or the new book.</summary>
    public static (string? Problem, string? Book) RoutineAddParts(string book, string name, string when, string request)
    {
        var n = Call("routines.addParts", O(("book", book), ("name", name), ("when", when), ("request", request)))!;
        return (S(n["problem"]), S(n["book"]));
    }

    public static (string? Removed, string Book) RoutineRemoveNamed(string book, string name)
    {
        var n = Call("routines.removeNamed", O(("book", book), ("name", name)))!;
        return (S(n["removed"]), S(n["book"]) ?? book);
    }

    public static string RoutineRemoveId(string book, string id) => S(Call("routines.removeID", O(("book", book), ("routineID", id)))) ?? book;
    public static string? RoutineMatching(string book, string transcript) => S(Call("routines.matching", O(("book", book), ("transcript", transcript))));

    /// <summary>Marks what it returns as run, so it can't run twice for the same time.</summary>
    public static (List<string> Requests, string Book) RoutinesDue(string book)
    {
        var n = Call("routines.due", O(("book", book)))!;
        return (L(n["requests"]), S(n["book"]) ?? book);
    }

    public static List<RoutineRow> RoutineList(string book) =>
        (Call("routines.list", O(("book", book))) as JsonArray)?.Select(r => new RoutineRow(S(r!["id"])!, S(r["name"])!, S(r["when"])!, S(r["request"])!)).ToList() ?? new();
}
