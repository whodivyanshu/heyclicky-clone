using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Media;
using System.Windows.Threading;

namespace Jarvis;

public enum CompanionMode { Idle, Listening, Thinking, Speaking }

/// <summary>
/// Runs a turn (hold to talk or type, then capture, ask, speak and point) and any walkthrough or job that follows.
/// A port of the Mac app's Coordinator. Everything here runs on the UI thread, so its state needs no locks, and each
/// turn's cancellation stands in for cancelling a Swift Task.
/// </summary>
public sealed partial class Coordinator
{
    public readonly AppSettings Settings;
    public readonly OverlayController Overlay = new();
    public readonly IslandModel Island = new();
    public Action<CompanionMode> OnModeChange = _ => { };
    public Action OpenSettings = () => { };
    public Action<bool> OnMeetingChange = _ => { };

    private readonly HotkeyMonitor hotkeys = new();
    private readonly SpeechInput speechIn = new();
    public readonly SpeechOutput SpeechOut = new();
    private CompanionMode mode = CompanionMode.Idle;
    private DateTime? pressedAt;
    private bool isListening;
    private CancellationTokenSource? turn;
    private List<ScreenMap> screens = new();
    private List<ChatTurn> history = new();
    private bool didPoint, allowsActions, sawAction, didRunAction, isTurnRecorded;
    private string? actionFailure;
    private CancellationTokenSource? returnTask;

    /// <summary>Set while a request is running with full control turned on. The session itself is kept in the core.</summary>
    private int? control;
    private string controlPlanText = "";
    private int controlStep = 1;
    private bool wantsNextStep;
    private bool didOpenSomething, abandonedReply, sawDone, sawTarget, ranScreenAction, ranClickOrKeys, sawPoint, madePlan;
    private byte[]? beforeOpening;
    private Task<Look>? pendingLook;
    private readonly List<Beat> heldBeats = new();
    private string? lastTyped;
    private bool isDirectRequest;
    private List<ScreenControl> controls = new();

    private string? declaredConfirmation;
    private TaskCompletionSource<bool>? pendingConfirmation;
    private CancellationTokenSource? confirmationTimeout;
    private bool isAnsweringConfirmation;

    private readonly List<string> lookupResults = new();
    private int lookupRounds;
    private bool answeringLookup, unattended;
    private string requestText = "";
    private Guid conversationId = Guid.NewGuid();
    private byte[]? latestScreenshot;

    private readonly WakeWordListener wakeWord = new();
    private readonly BargeInListener bargeIn = new();
    private bool isBargeCapturing, isDictating;
    private readonly MeetingRecorder meetingRecorder = new();
    private MeetingNote? currentMeeting;
    private CancellationTokenSource? meetingLimit;
    private CancellationTokenSource? wakeWordUpdate;
    private bool isWakeCapturing, isFollowingUp, lastTurnWasVoice, isWatching;
    private DateTime? followUpHeardAt;
    private byte[]? lastWatched;
    private readonly int watchRules = Core.WatchNew();

    private int? guide;
    private ClickMonitor? clickMonitor;
    private CancellationTokenSource? guideTimeout;

    private const double MinimumHold = 0.25;
    private const int HistoryLimit = 6, MaxLookupRounds = 3;
    /// <summary>Silent steps have no words, and an empty turn in the history can be rejected by the provider.</summary>
    private const string WorkingPlaceholder = "Working on it.";
    private const int PointHoldAfterSpeechMs = 2500;
    private const double ReplyLinger = 5;
    private static readonly (double Minimum, double Limit) SettleAfterClick = (0.35, 0.7), SettleAfterOpening = (0.3, 1.5);
    private static readonly TimeSpan GuideWait = TimeSpan.FromSeconds(120), ConfirmationWait = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan LongestMeeting = TimeSpan.FromHours(3);

    public Coordinator(AppSettings settings) => Settings = settings;

    public void Start()
    {
        Overlay.ShowWhenIdle = () => Settings.Data.ShowWhenIdle;
        Overlay.Start();

        hotkeys.Hotkey = () => Settings.Data.Hotkey;
        hotkeys.OnPress = Pressed;
        hotkeys.OnRelease = Released;
        hotkeys.OnEscape = Escape;
        hotkeys.Start();

        speechIn.OnLevel = level =>
        {
            Overlay.Level = level;
            Island.Level = level;
        };
        speechIn.OnPartial = text =>
        {
            if (!isListening) return;
            Island.Transcript = text;
            if (isFollowingUp) followUpHeardAt = DateTime.UtcNow;
        };

        SpeechOut.GetVoiceConfig = Settings.VoiceConfig;
        SpeechOut.OnPoint = PointAt;
        SpeechOut.OnTarget = Target;
        SpeechOut.OnAction = Act;
        SpeechOut.OnClick = Click;
        SpeechOut.OnDrained = SpeechFinished;
        SpeechOut.OnVoiceError = message => Island.Notice = message;

        Island.OnAsk = text => Ask(text);
        Island.OnStop = Escape;
        Island.OnConfirm = ResolveConfirmation;
        Island.OnOpenSettings = () =>
        {
            Island.IsOpen = false;
            OpenSettings();
        };

        ActionRunner.Policy = () => Settings.Data.AppPolicy;
        StartAutomation();
        StartVoiceFeatures();
    }

    /// <summary>Saves the conversation as it stands. The reply can still change until the job ends.</summary>
    private void SaveLatestTurn()
    {
        if (!Settings.Data.SaveConversations || history.Count == 0) return;
        var last = history[^1];
        Settings.Conversations.Save(new ConversationEntry { Id = conversationId, Date = DateTime.Now, User = last.User, Assistant = last.Assistant });
    }

    private void SetHistory(List<ChatTurn> turns)
    {
        history = turns;
        SaveLatestTurn();
    }

    /// <summary>Dev check from --demo: plays through every island state and the pointer's flight, needing no setup.</summary>
    public async void RunDemo()
    {
        var display = ScreenCapture.DisplayAtCursor();
        static Task Wait(double seconds) => Task.Delay(TimeSpan.FromSeconds(seconds));
        Island.Transcript = "";
        Island.Show(IslandPhase.Listening);
        foreach (var words in new[] { "How", "How do I", "How do I export", "How do I export this as a PDF?" })
        {
            Island.Level = 0.7f;
            Island.Transcript = words;
            await Wait(0.7);
        }
        Island.Level = 0;
        Island.Show(IslandPhase.Thinking);
        await Wait(1.5);
        Island.Reply = "Open the File menu first, then look for Export.";
        Island.Show(IslandPhase.Speaking);
        SetMode(CompanionMode.Speaking);
        Overlay.Fly(display.X + display.Width / 2.0, display.Y + display.Height / 2.0, "File menu", 40);
        await Wait(3);
        Island.GuideStep = 1;
        Island.Show(IslandPhase.Guiding);
        SetMode(CompanionMode.Idle);
        await Wait(3);
        Island.ConfirmTitle = "Press Return in WhatsApp";
        Island.ConfirmDetail = "Send \"How are you?\" to Lovesh\nTyped: How are you?";
        Island.Show(IslandPhase.Confirming);
        await Wait(4);
        Overlay.ReturnToCursor();
        Island.Rest();
    }

    private void SetMode(CompanionMode next)
    {
        mode = next;
        Overlay.SetMode(next);
        OnModeChange(next);
        UpdateWakeWord();
        UpdateBargeIn();
    }

    private void ShowError(Exception error)
    {
        SystemSounds.Hand.Play();
        EndGuide();
        Overlay.ReturnToCursor();
        Island.ShowMessage(MessageOf(error));
        SetMode(CompanionMode.Idle);
    }

    /// <summary>Only our own messages are shown. Anything unexpected goes to the log, since its text can be technical or hold private details.</summary>
    private static string MessageOf(Exception error)
    {
        if (error is JarvisMessage) return error.Message;
        Log.Write($"Unexpected: {error.GetType().Name}");
        return "Something went wrong. Please try that again.";
    }

    private CancellationToken NewTurn()
    {
        turn?.Cancel();
        turn = new CancellationTokenSource();
        return turn.Token;
    }

    // MARK: Hold to talk, typed questions and stopping

    private void Pressed()
    {
        // Holding the shortcut while Jarvis is asking answers the question, rather than stopping the job.
        if (pendingConfirmation is not null)
        {
            StartAnsweringConfirmation();
            return;
        }
        Interrupt();
        lastTurnWasVoice = true;
        Island.IsOpen = false;
        pressedAt = DateTime.UtcNow;
        isListening = true;
        SetMode(CompanionMode.Listening);
        Island.Rest();
        Island.Show(IslandPhase.Listening);
        try { speechIn.Start(Settings.ListeningLanguage); }
        catch (JarvisMessage problem)
        {
            isListening = false;
            ShowError(problem);
            if (!SpeechModel.IsInstalled) OpenSettings();
        }
    }

    private void Released()
    {
        if (!isListening) return;
        isListening = false;
        Overlay.Level = 0;
        Island.Level = 0;

        if (isAnsweringConfirmation)
        {
            FinishAnsweringConfirmation();
            return;
        }
        if (pressedAt is { } at && (DateTime.UtcNow - at).TotalSeconds < MinimumHold)
        {
            // Probably part of another keyboard shortcut.
            speechIn.Cancel();
            Island.Rest();
            SetMode(CompanionMode.Idle);
            return;
        }
        // Taken now so it's ready when the transcript is. It stays on this PC unless the request goes to the model.
        pendingLook = LookNow(readsControls: true);
        _ = RunVoiceTurn(NewTurn());
    }

    private async Task RunVoiceTurn(CancellationToken cancel)
    {
        try
        {
            var transcript = await speechIn.Stop();
            cancel.ThrowIfCancellationRequested();
            if (transcript.Length == 0)
            {
                DiscardPendingLook();
                Island.ShowMessage("Didn't catch that.", 2);
                SetMode(CompanionMode.Idle);
                return;
            }
            StartRequest(transcript);
            await Perform(transcript, cancel);
        }
        catch (OperationCanceledException) { /* Whatever interrupted the turn has already reset the state. */ }
        catch (Exception error) { if (!cancel.IsCancellationRequested) ShowError(error); }
    }

    /// <summary>A typed question or a suggestion from the island's panel.</summary>
    private void Ask(string text, bool byVoice = false)
    {
        Interrupt();
        lastTurnWasVoice = byVoice;
        Island.IsOpen = false;
        Island.Rest();
        StartRequest(text);
        _ = Perform(text, NewTurn());
    }

    private void Escape()
    {
        if (mode == CompanionMode.Idle && guide is null && Island.Phase == IslandPhase.Resting) return;
        isListening = false;
        Interrupt();
        Overlay.SetCaption(null);
        Overlay.Level = 0;
        Island.Rest();
        SetMode(CompanionMode.Idle);
    }

    private void Interrupt()
    {
        // Answers first, so the waiting step can finish. Anything that interrupts a question is a no.
        ResolveConfirmation(false);
        turn?.Cancel();
        turn = null;
        // Stop first, so the microphone isn't still open when the shortcut's own listening starts.
        if (isWakeCapturing) wakeWord.Stop();
        isWakeCapturing = false;
        if (isBargeCapturing) bargeIn.Stop();
        isBargeCapturing = false;
        if (isDictating) isListening = false;
        isDictating = false;
        if (isFollowingUp) isListening = false;
        isFollowingUp = false;
        lookupResults.Clear();
        DiscardPendingLook();
        returnTask?.Cancel();
        returnTask = null;
        EndGuide();
        speechIn.Cancel();
        SpeechOut.Stop();
        Overlay.ReturnToCursor();
        didPoint = false;
        EndControl();
        wantsNextStep = false;
        heldBeats.Clear();
    }

    private void EndControl()
    {
        if (control is { } id) Core.SessionFree(id);
        control = null;
        controlPlanText = "";
        controlStep = 1;
    }

    private void StartRequest(string text)
    {
        EndGuide();
        guide = Core.GuideNew(text);
        EndControl();
        control = Settings.Data.ControlsPC ? Core.SessionNew(text) : null;
        lastTyped = null;
        requestText = text;
        conversationId = Guid.NewGuid();
        lookupResults.Clear();
        lookupRounds = 0;
        answeringLookup = false;
        unattended = false;
        latestScreenshot = null;
    }

    // MARK: One round with the AI

    private async Task Perform(string spoken, CancellationToken cancel)
    {
        if (RunMeetingCommand(spoken)) return;
        // Saying a routine's phrase asks for what it stands for, in every way after this point.
        var transcript = spoken;
        if (Core.RoutineMatching(Settings.Routines.Book, spoken) is { } request)
        {
            transcript = request;
            var keepsUnattended = unattended;
            StartRequest(request);
            unattended = keepsUnattended;
            if (unattended) EndControl();
        }
        if (RunQuickCommand(transcript)) return;
        try
        {
            await Exchange(transcript, null, transcript, false, false, cancel);
        }
        catch (OperationCanceledException) { /* Whatever interrupted the turn has already reset the state. */ }
        catch (Exception error) { if (!cancel.IsCancellationRequested) ShowError(error); }
    }

    /// <summary>Runs a simple command without asking the model. Returns false if the model should handle it.</summary>
    private bool RunQuickCommand(string transcript)
    {
        var tag = Core.QuickAction(transcript, ActionRunner.InstalledAppNames, ActionRunner.RunningAppNames);
        if (tag is null) return false;
        DiscardPendingLook();
        EndControl();
        ResetTurnState();
        allowsActions = true;
        isDirectRequest = true;

        var said = Core.QuickConfirmation(tag, Settings.Data.HindiAssistant);
        Island.Reply = said;
        SetMode(CompanionMode.Speaking);
        Island.Show(IslandPhase.Speaking);
        SpeechOut.Begin();
        SpeechOut.Enqueue(new Beat[] { new Beat.Act(tag), new Beat.Say(said) });
        SetHistory(history.Append(new ChatTurn(transcript, said)).TakeLast(HistoryLimit).ToList());
        Island.Conversation = history;
        isTurnRecorded = true;
        SpeechOut.FinishInput();
        return true;
    }

    private void ResetTurnState()
    {
        Island.Notice = "";
        Island.Activity = "";
        sawAction = didRunAction = didOpenSomething = wantsNextStep = isTurnRecorded = abandonedReply = false;
        sawDone = sawTarget = ranScreenAction = ranClickOrKeys = sawPoint = madePlan = false;
        actionFailure = null;
        beforeOpening = null;
        heldBeats.Clear();
        declaredConfirmation = null;
    }

    private sealed record Look(List<CapturedScreen> Captured, List<ScreenControl> Controls);

    /// <summary>
    /// One round with the AI: takes fresh screenshots, streams the reply, and hands it to speech.
    /// `continuesRequest` marks a later step of a request Jarvis is carrying out by itself.
    /// </summary>
    private async Task Exchange(string transcript, string? guidance, string historyEntry, bool continuesRequest, bool answering, CancellationToken cancel)
    {
        answeringLookup = answering;
        // Data that was just looked up is all a plain answer needs. A job still in progress has to see where it's up to.
        var looksAtScreen = !unattended && (!answering || control is not null);
        SetMode(CompanionMode.Thinking);
        Island.Reply = "";
        if (!looksAtScreen && Island.Progress.Length == 0) Island.Progress = "Thinking…";
        Island.Show(IslandPhase.Thinking);
        // Walkthrough follow-ups have no new words from the user, so only a direct request can act,
        // along with the later steps of a request they gave Jarvis to carry out.
        allowsActions = guidance is null || continuesRequest;
        isDirectRequest = guidance is null;
        ResetTurnState();

        var provider = Settings.MakeProvider();
        Look seen;
        if (!looksAtScreen) seen = new Look(new(), new());
        else if (pendingLook is { } waiting)
        {
            pendingLook = null;
            seen = await waiting;
        }
        else seen = await LookNow(readsControls: true);
        cancel.ThrowIfCancellationRequested();

        var captured = seen.Captured;
        latestScreenshot = Settings.Data.KeepActivityScreenshots ? captured.FirstOrDefault()?.Jpeg : null;
        screens = captured.Select(c => c.Map).ToList();
        controls = seen.Controls;

        var request = new AIRequest(
            Core.SystemPrompt(control is not null, Settings.Data.HindiAssistant, Settings.Memory.Facts, Settings.Data.ScreenMemoryEnabled, TeachingNotes()),
            history,
            UserMessage(transcript, guidance, captured),
            captured.Select(c => c.Jpeg).ToList());

        var parser = Core.ParserNew();
        var reply = "";
        SpeechOut.Begin();
        try
        {
            await foreach (var chunk in provider.Stream(request, cancel).WithCancellation(cancel))
            {
                cancel.ThrowIfCancellationRequested();
                reply += chunk;
                Deliver(Core.ParserFeed(parser, chunk));
            }
            cancel.ThrowIfCancellationRequested();
            Deliver(Core.ParserFinish(parser));
            parser = 0;
        }
        finally
        {
            if (parser != 0) Core.ParserFree(parser);
        }

        if (control is { } session && allowsActions && ranScreenAction && !sawDone && !sawTarget
            && Core.SessionNeedsAnotherLook(session, ranClickOrKeys, madePlan))
        {
            // It acted without saying it was finished, so look at the result instead of stopping partway through.
            wantsNextStep = true;
        }
        ReleaseHeldBeats();

        var spoken = Core.SpokenText(reply);
        if (spoken.Length == 0 && !didPoint && !sawAction) throw new JarvisMessage("The model sent back an empty reply.");
        var said = actionFailure ?? (abandonedReply ? "" : spoken);
        var turns = history.ToList();
        if (continuesRequest && turns.Count > 0)
        {
            // One request stays one turn, however many steps it took, so it doesn't push out the conversation.
            var last = turns[^1];
            var earlier = last.Assistant == WorkingPlaceholder ? "" : last.Assistant;
            var merged = string.Join(" ", new[] { earlier, said }.Where(t => t.Length > 0));
            turns[^1] = new ChatTurn(last.User, merged.Length == 0 ? WorkingPlaceholder : merged);
        }
        else turns.Add(new ChatTurn(historyEntry, said.Length == 0 ? WorkingPlaceholder : said));
        SetHistory(turns.TakeLast(HistoryLimit).ToList());
        Island.Conversation = history;
        isTurnRecorded = true;
        SpeechOut.FinishInput();
    }

    /// <summary>Takes the screenshot and reads the front window's controls at the same time.</summary>
    private async Task<Look> LookNow(bool readsControls)
    {
        var finding = readsControls ? UIInspector.StartFindingControls() : Task.FromResult(new List<UIInspector.FoundControl>());
        var captured = await ScreenCapture.CaptureAll();
        var found = await finding;
        return new Look(captured, UIInspector.Controls(found, captured.Select(c => c.Map).ToList()));
    }

    private void DiscardPendingLook()
    {
        pendingLook = null;
    }

    private string UserMessage(string transcript, string? guidance, List<CapturedScreen> captured)
    {
        var (mouseX, mouseY) = Win32.CursorPosition();
        CursorInfo? cursor = null;
        foreach (var screen in captured)
        {
            var map = screen.Map;
            if (mouseX < map.X || mouseX >= map.X + map.Width || mouseY < map.Y || mouseY >= map.Y + map.Height) continue;
            var (x, y) = Core.ImagePoint(map, mouseX, mouseY);
            cursor = new CursorInfo(map.Index, (int)x, (int)y);
            break;
        }
        var front = ForegroundApp.Current();
        return Core.UserMessage(
            transcript, guidance, captured.Select(c => c.Map), cursor,
            front is { IsJarvis: false } ? front.DisplayName : null,
            guidance is null ? UIInspector.SelectedText() : null,
            guidance is null && Core.MentionsClipboard(transcript) ? ActionRunner.ClipboardText() : null,
            controls,
            // Both spoken and exact, so the model can write dates in tags without working out the calendar.
            DateTime.Now.ToString("dddd, yyyy-MM-dd'T'HH:mm", CultureInfo.InvariantCulture));
    }

    /// <summary>Notes for the app in front of them, when they've asked to learn something.</summary>
    private string? TeachingNotes() => Settings.Data.TeachingEnabled
        ? Core.TeachingNotes(ForegroundApp.Current()?.DisplayName, requestText, TeachingFiles.Custom())
        : null;

    private void Deliver(List<Beat> beats)
    {
        if (beats.Count == 0) return;
        if (mode != CompanionMode.Speaking) SetMode(CompanionMode.Speaking);
        var now = new List<Beat>();
        foreach (var beat in beats)
        {
            switch (beat)
            {
                case Beat.Say say:
                    if (actionFailure is not null || abandonedReply) continue;
                    Island.Reply += Island.Reply.Length == 0 ? say.Text : " " + say.Text;
                    break;
                case Beat.Act act:
                    sawAction = true;
                    if (act.Tag.Kind == "PLAN") madePlan = true;
                    var info = Core.Info(act.Tag.Kind);
                    if (info.ChangesScreen)
                    {
                        ranScreenAction = true;
                        if (!info.CanFinishRequest) ranClickOrKeys = true;
                    }
                    break;
                case Beat.Click:
                    sawAction = ranScreenAction = ranClickOrKeys = true;
                    break;
                case Beat.Next:
                    sawAction = true;
                    wantsNextStep = allowsActions && control is not null;
                    break;
                case Beat.Done:
                    sawAction = sawDone = true;
                    break;
                case Beat.Target:
                    sawTarget = true;
                    break;
                case Beat.Point:
                    sawPoint = true;
                    break;
            }
            // Actions run right away. Pointing stays in step with the words around it.
            if (beat is Beat.Say or Beat.Point or Beat.Target)
            {
                if (control is not null) heldBeats.Add(beat); else now.Add(beat);
            }
            else now.Add(beat);
        }
        if (Island.Phase == IslandPhase.Thinking) Island.Show(IslandPhase.Speaking);
        SpeechOut.Enqueue(now);
    }

    /// <summary>Jarvis works silently, so words are spoken only once there's nothing left to do.</summary>
    private void ReleaseHeldBeats()
    {
        var beats = heldBeats.ToList();
        heldBeats.Clear();
        if (wantsNextStep) beats.RemoveAll(b => b is Beat.Say);
        else if (control is not null && sawDone && !beats.Any(b => b is Beat.Say))
        {
            var word = Settings.Data.HindiAssistant ? "हो गया।" : "Done.";
            Island.Reply = word;
            beats.Add(new Beat.Say(word));
        }
        SpeechOut.Enqueue(beats);
    }

    // MARK: Carrying out what a reply asks for

    /// <summary>Returns what to say instead of the model's reply if the action failed.</summary>
    private async Task<string?> Act(ActionTag tag, CancellationToken cancel)
    {
        // After a failure the rest of the reply was planned for a screen that isn't there.
        if (!allowsActions || actionFailure is not null || abandonedReply) return null;
        var info = Core.Info(tag.Kind);
        // Looked-up data can come from anyone, so it can't lead to opening or typing anything without full control.
        if (answeringLookup && control is null && !info.IsNative && tag.Kind != "COPY") return null;
        if (info.IsNative) return await ActNatively(tag, info, cancel);
        switch (tag.Kind)
        {
            case "ADD_ROUTINE":
            case "REMOVE_ROUTINE":
                return ActOnRoutine(tag);
            case "PLAN":
                if (control is { } session)
                {
                    Core.SessionSetPlan(session, tag.Value);
                    controlPlanText = tag.Value.Trim();
                }
                return null;
            case "CONFIRM":
                declaredConfirmation = tag.Value;
                return null;
            case "REMEMBER":
                if (isDirectRequest && Settings.Memory.Add(tag.Value) is { } saved) Island.Activity = "Remembered: " + saved;
                return null;
            case "FORGET":
                if (isDirectRequest) Island.Activity = Settings.Memory.Forget(tag.Value).Count == 0 ? "Nothing saved about that" : "Forgot that";
                return null;
            case "COPY":
                Island.Activity = ActionRunner.Progress(tag);
                return Report(await ActionRunner.Run(tag, cancel));
        }

        if (info.UsesKeyboard)
        {
            if (control is null)
                return Report(new ActionResult("Didn't type", "I can't use your keyboard unless you turn on full control in Settings."));
            if (didOpenSomething)
                return Report(new ActionResult("Didn't type", "The new window may not have been ready, so I stopped before typing. Ask me again and I'll take a fresh look.", Retryable: true));
        }
        else didOpenSomething = true;

        bool needsYes;
        var title = ActionRunner.Progress(tag).TrimEnd('…');
        if (tag.Kind == "KEY")
        {
            var context = UIInspector.CurrentKeyContext();
            needsYes = declaredConfirmation is not null || Core.KeyNeedsConfirmation(tag.Value, context);
            title = $"Press {tag.Value} in {context.AppName}";
        }
        else needsYes = declaredConfirmation is not null;

        if (needsYes)
        {
            var app = ForegroundApp.Current()?.ProcessId;
            var approved = await AskToConfirm(title, cancel);
            cancel.ThrowIfCancellationRequested();
            if (!approved) return Declined();
            if (ForegroundApp.Current()?.ProcessId != app) return ScreenChanged();
        }

        didRunAction = true;
        Island.Activity = ActionRunner.Progress(tag);
        if (control is not null && !info.UsesKeyboard)
        {
            beforeOpening = await ScreenCapture.Thumbnail();
            cancel.ThrowIfCancellationRequested();
        }
        var result = await ActionRunner.Run(tag, cancel);
        if (result.Failure is null && tag.Kind is "TYPE" or "PASTE") lastTyped = tag.Value;
        return Report(result);
    }

    /// <summary>
    /// Uses an app's data directly. Their own new words can do this right away. A later step follows a screenshot or
    /// looked-up data, which anyone could have written, so it asks first.
    /// </summary>
    private async Task<string?> ActNatively(ActionTag tag, ActionInfo info, CancellationToken cancel)
    {
        if (!isDirectRequest)
        {
            var approved = await AskToConfirm(ActionRunner.Progress(tag).TrimEnd('…'), cancel);
            cancel.ThrowIfCancellationRequested();
            if (!approved) return Declined();
        }
        Island.Activity = ActionRunner.Progress(tag);
        if (info.ChangesScreen)
        {
            didRunAction = true;
            didOpenSomething = true;
        }
        var result = tag.Kind == "RECALL" ? RecallFromScreenMemory(tag.Value) : await ActionRunner.Run(tag, cancel);
        cancel.ThrowIfCancellationRequested();
        if (result.Failure is null && result.Data is { } data) lookupResults.Add(data);
        return Report(result);
    }

    private ActionResult RecallFromScreenMemory(string query)
    {
        if (!Settings.Data.ScreenMemoryEnabled)
            return new ActionResult("Screen memory is off", "Screen memory is turned off. You can turn it on in Settings.");
        var lines = Settings.ScreenMemory.Search(query, 10).Select(hit => $"- {hit.Date.ToString("ddd d MMM HH:mm", CultureInfo.InvariantCulture)} in {hit.App}: {hit.Snippet}").ToList();
        return new ActionResult("Searched your screen memory",
            Data: lines.Count == 0 ? $"Nothing on screen matched {query}." : "What was on screen:\n" + string.Join("\n", lines));
    }

    /// <summary>Flies the pointer to the target so they can see what's about to happen, then clicks it.</summary>
    private async Task<string?> Click(PointTag original, CancellationToken cancel)
    {
        // Walkthrough follow-ups have no new words from the user, so show the target and leave the click to them.
        if (!allowsActions || (answeringLookup && control is null))
        {
            PointAt(original);
            return null;
        }
        if (unattended)
            return Report(new ActionResult($"Didn't click {original.Label ?? "that"}", "A scheduled routine can't click anything, in case you're away."));
        if (actionFailure is not null || abandonedReply) return null;
        var tag = Core.Snap(original, controls);
        if (didRunAction || ScreenFor(tag) is not { } screen)
            return Report(new ActionResult($"Didn't click {tag.Label ?? "that"}", "The screen may have changed, so I didn't click. Ask me again and I'll take a fresh look.", Retryable: true));

        didRunAction = true;
        didPoint = true;
        Island.Activity = $"Clicking {tag.Label ?? "that"}…";
        var (x, y) = Core.GlobalPoint(screen, tag.X, tag.Y);
        var flight = Overlay.Fly(x, y, tag.Label);
        // Esc or the shortcut during the flight has to stop the click.
        await Task.Delay(TimeSpan.FromSeconds(flight), cancel);

        // What the app calls the control counts as much as what the model calls it.
        int clickX = (int)Math.Round(x), clickY = (int)Math.Round(y);
        var labels = await Task.Run(() => UIInspector.LabelsAt(clickX, clickY), cancel);
        var risky = Core.RiskyLabel(tag.Label is null ? labels : labels.Append(tag.Label));
        if (risky is not null || declaredConfirmation is not null)
        {
            var app = ForegroundApp.Current();
            var name = risky ?? labels.FirstOrDefault() ?? tag.Label ?? "that";
            var approved = await AskToConfirm($"Click \"{name}\" in {app?.DisplayName ?? "this app"}", cancel);
            cancel.ThrowIfCancellationRequested();
            if (!approved) return Declined();
            // Whatever they approved has to still be what's under the pointer.
            var labelsNow = await Task.Run(() => UIInspector.LabelsAt(clickX, clickY), cancel);
            if (ForegroundApp.Current()?.ProcessId != app?.ProcessId || !labelsNow.SequenceEqual(labels)) return ScreenChanged();
        }

        var result = await ActionRunner.Click(clickX, clickY, tag.Label, cancel);
        cancel.ThrowIfCancellationRequested();
        return Report(result);
    }

    private string? Declined() => Report(new ActionResult("Left that to you", Settings.Data.HindiAssistant ? "ठीक है, मैंने वह नहीं किया।" : "Okay, I didn't do that."));
    private string? ScreenChanged() => Report(new ActionResult("Stopped", "The screen changed while I was asking, so I didn't do it."));

    private string? Report(ActionResult result)
    {
        if (Settings.Data.KeepActivityLog && result.Summary.Length > 0)
            Settings.Activity.Add(requestText, result.Summary, result.Failure, latestScreenshot);
        // A failure is explained in the reply itself, so only success gets the checkmark line.
        Island.Activity = result.Failure is null ? result.Summary : "";
        if (result.Failure is not { } failure)
        {
            if (control is { } session) Core.SessionRecord(session, result.Summary);
            return null;
        }
        if (result.Retryable && control is { } job && Core.SessionRecordFailure(job, failure))
        {
            abandonedReply = true;
            wantsNextStep = true;
            heldBeats.Clear();
            return "";
        }
        actionFailure = failure;
        Island.Reply = failure;
        // The reply may already be in the history, and it shouldn't claim something happened that didn't.
        if (isTurnRecorded && history.Count > 0)
        {
            var turns = history.ToList();
            turns[^1] = new ChatTurn(turns[^1].User, failure);
            SetHistory(turns);
            Island.Conversation = history;
        }
        return failure;
    }

    private void PointAt(PointTag tag)
    {
        if (ScreenFor(tag) is not { } screen) return;
        didPoint = true;
        var (x, y) = Core.GlobalPoint(screen, tag.X, tag.Y);
        Overlay.Fly(x, y, tag.Label);
    }

    private ScreenMap? ScreenFor(PointTag tag) => screens.FirstOrDefault(s => s.Index == (tag.Screen ?? 1));

    private async void SpeechFinished()
    {
        SetMode(CompanionMode.Idle);
        if (guide is { } current && Core.GuideCurrent(current) is not null) return;
        if (ContinueAfterLookup()) return;
        if (ContinueRequest()) return;
        EndGuide();
        Island.RestAfter(ReplyLinger);
        ListenForFollowUp();
        if (!didPoint) return;
        didPoint = false;
        // Leave the pointer on the target long enough to act on it.
        var cancel = returnTask = new CancellationTokenSource();
        try
        {
            await Task.Delay(PointHoldAfterSpeechMs, cancel.Token);
            Overlay.ReturnToCursor();
        }
        catch (OperationCanceledException) { }
    }

    // MARK: Requests that take several rounds

    /// <summary>Sends looked-up data back to the model, so it can answer from it.</summary>
    private bool ContinueAfterLookup()
    {
        var results = lookupResults.ToList();
        lookupResults.Clear();
        if (results.Count == 0 || actionFailure is not null || lookupRounds >= MaxLookupRounds) return false;
        lookupRounds++;
        wantsNextStep = false;
        var task = requestText;
        var guidance = Core.LookupGuidance(task, results);
        if (control is { } session) guidance += "\n" + Core.SessionFollowUp(session);
        Island.Progress = Settings.Data.HindiAssistant ? "देख रहा हूँ…" : "Reading what I found…";
        SetMode(CompanionMode.Thinking);
        Island.Show(IslandPhase.Thinking);
        var cancel = NewTurn();
        _ = Guarded(() => Exchange(task, guidance, task, true, true, cancel), cancel);
        return true;
    }

    /// <summary>Runs a later round, reporting failures the way the first round does.</summary>
    private async Task Guarded(Func<Task> work, CancellationToken cancel)
    {
        try { await work(); }
        catch (OperationCanceledException) { /* Whatever interrupted the turn has already reset the state. */ }
        catch (Exception error) { if (!cancel.IsCancellationRequested) ShowError(error); }
    }

    /// <summary>Starts the next step if the model asked for one. A failed action ends the request.</summary>
    private bool ContinueRequest()
    {
        if (!wantsNextStep || actionFailure is not null || control is not { } session) return false;
        wantsNextStep = false;
        didPoint = false;
        Overlay.ReturnToCursor();

        if (!Core.SessionAdvance(session))
        {
            EndControl();
            const string limit = "I've stopped after 30 steps. Ask me again if there's more to do.";
            SpeechOut.Begin();
            SpeechOut.Enqueue(new Beat[] { new Beat.Say(limit) });
            Island.Reply = limit;
            Island.Show(IslandPhase.Speaking);
            SpeechOut.FinishInput();
            return true;
        }
        controlStep++;
        var task = requestText;
        var guidance = Core.SessionFollowUp(session);
        var opened = didOpenSomething;
        var before = beforeOpening;
        // A reply with nothing but NEXT is waiting for something to load, and that can look settled until it arrives.
        var ranSomething = ranScreenAction;
        Island.Progress = controlPlanText.Length > 0 ? $"Step {controlStep}: {controlPlanText}" : $"Step {controlStep}";
        SetMode(CompanionMode.Thinking);
        Island.Show(IslandPhase.Thinking);
        var cancel = NewTurn();
        _ = Guarded(async () =>
        {
            if (opened)
                await ScreenCapture.WaitUntilSettled(cancel, before, requiresChange: true, atLeast: SettleAfterOpening.Minimum, limit: SettleAfterOpening.Limit);
            else
                await ScreenCapture.WaitUntilSettled(cancel, atLeast: ranSomething ? SettleAfterClick.Minimum : SettleAfterClick.Limit, limit: SettleAfterClick.Limit);
            await Exchange(task, guidance, task, true, false, cancel);
        }, cancel);
        return true;
    }

    private void Target(PointTag tag)
    {
        if (ScreenFor(tag) is not { } screen || guide is not { } session || !Core.GuideSetTarget(session, tag))
        {
            // No guide to attach to, or out of steps: still show the location.
            PointAt(tag);
            return;
        }
        didPoint = true;
        var (x, y) = Core.GlobalPoint(screen, tag.X, tag.Y);
        Overlay.Fly(x, y, tag.Label, (tag.Radius ?? 0) * screen.Width / screen.ImageWidth);
        Island.GuideStep = guideCompleted + 1;
        Island.Show(IslandPhase.Guiding);
        WatchForClick();
    }

    private int guideCompleted;

    /// <summary>Clicks go through to the app as usual. Jarvis only notices where they landed.</summary>
    private async void WatchForClick()
    {
        StopWatchingForClick();
        clickMonitor = new ClickMonitor(Clicked);
        var cancel = guideTimeout = new CancellationTokenSource();
        try
        {
            await Task.Delay(GuideWait, cancel.Token);
            FinishGuideQuietly();
        }
        catch (OperationCanceledException) { }
    }

    private void Clicked(int x, int y)
    {
        if (guide is not { } session || Core.GuideCurrent(session) is not { } tag || ScreenFor(tag) is not { } screen) return;
        if (!Core.GuideIsHit(session, screen, x, y))
        {
            // They've gone off to do something else, so step back without nagging.
            FinishGuideQuietly();
            return;
        }

        StopWatchingForClick();
        turn?.Cancel();
        SpeechOut.Stop();
        Overlay.ReturnToCursor();
        didPoint = false;

        var name = Core.GuideComplete(session);
        guideCompleted++;
        conversationId = Guid.NewGuid();
        var task = requestText;
        var guidance = Core.GuideFollowUp(session);
        SetMode(CompanionMode.Thinking);
        Island.Show(IslandPhase.Thinking);

        var cancel = NewTurn();
        _ = Guarded(async () =>
        {
            await ScreenCapture.WaitUntilSettled(cancel, atLeast: SettleAfterClick.Minimum, limit: SettleAfterClick.Limit);
            await Exchange(task, guidance, $"(clicked {name})", false, false, cancel);
        }, cancel);
    }

    private void FinishGuideQuietly()
    {
        EndGuide();
        didPoint = false;
        Overlay.ReturnToCursor();
        Island.Rest();
    }

    private void EndGuide()
    {
        if (guide is { } id) Core.GuideFree(id);
        guide = null;
        guideCompleted = 0;
        StopWatchingForClick();
    }

    private void StopWatchingForClick()
    {
        clickMonitor?.Dispose();
        clickMonitor = null;
        guideTimeout?.Cancel();
        guideTimeout = null;
    }

    // MARK: Asking for a yes

    /// <summary>Waits for a yes. The answer comes only from their voice, the island's buttons or Esc, so the model can't answer for them.</summary>
    private async Task<bool> AskToConfirm(string title, CancellationToken cancel)
    {
        if (cancel.IsCancellationRequested) return false;
        var summary = declaredConfirmation;
        declaredConfirmation = null;

        Island.ConfirmTitle = title;
        Island.ConfirmDetail = string.Join("\n", new[] { summary, lastTyped is null ? null : "Typed: " + (lastTyped.Length > 200 ? lastTyped[..200] : lastTyped) }.Where(t => t is not null));
        Island.Notice = "";
        Island.Show(IslandPhase.Confirming);
        SystemSounds.Asterisk.Play();
        SpeechOut.Announce(Settings.Data.HindiAssistant
            ? $"{summary ?? title}। क्या मैं कर दूँ?"
            : summary is not null ? $"{summary}. Should I go ahead?" : $"{title}. Should I go ahead?");

        var waiting = pendingConfirmation = new TaskCompletionSource<bool>();
        var timeout = confirmationTimeout = new CancellationTokenSource();
        _ = TimeOutConfirmation(timeout.Token);
        // Stopping the turn has to count as a no, whatever else is going on.
        using (cancel.Register(() => waiting.TrySetResult(false)))
        {
            var approved = await waiting.Task;
            if (pendingConfirmation == waiting) ResolveConfirmation(false);
            if (cancel.IsCancellationRequested) return false;
            Island.ConfirmTitle = "";
            Island.ConfirmDetail = "";
            Island.Notice = "";
            Island.Show(IslandPhase.Speaking);
            return approved;
        }
    }

    private async Task TimeOutConfirmation(CancellationToken cancel)
    {
        try
        {
            await Task.Delay(ConfirmationWait, cancel);
            ResolveConfirmation(false);
        }
        catch (OperationCanceledException) { }
    }

    private void ResolveConfirmation(bool approved)
    {
        if (pendingConfirmation is not { } pending) return;
        pendingConfirmation = null;
        confirmationTimeout?.Cancel();
        confirmationTimeout = null;
        if (isAnsweringConfirmation)
        {
            isAnsweringConfirmation = false;
            isListening = false;
            speechIn.Cancel();
        }
        SpeechOut.StopAnnouncement();
        pending.TrySetResult(approved);
    }

    private void StartAnsweringConfirmation()
    {
        SpeechOut.StopAnnouncement();
        isAnsweringConfirmation = true;
        isListening = true;
        pressedAt = DateTime.UtcNow;
        Island.Transcript = "";
        Island.Show(IslandPhase.Listening);
        try { speechIn.Start(Settings.ListeningLanguage); }
        catch (JarvisMessage problem)
        {
            Island.Notice = problem.Message;
            isListening = false;
            isAnsweringConfirmation = false;
            Island.Show(IslandPhase.Confirming);
        }
    }

    private async void FinishAnsweringConfirmation()
    {
        isAnsweringConfirmation = false;
        if (pressedAt is { } at && (DateTime.UtcNow - at).TotalSeconds < MinimumHold)
        {
            speechIn.Cancel();
            Island.Show(IslandPhase.Confirming);
            return;
        }
        string answer;
        try { answer = await speechIn.Stop(); }
        catch (Exception problem) when (problem is JarvisMessage or IOException) { answer = ""; }
        if (pendingConfirmation is null) return;
        if (Core.ConfirmationDecision(answer) is { } decision) ResolveConfirmation(decision);
        else
        {
            Island.Notice = "I didn't catch a yes or no.";
            Island.Show(IslandPhase.Confirming);
        }
    }
}
