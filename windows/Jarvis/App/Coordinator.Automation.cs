using System;
using System.Collections.Generic;
using System.Linq;
using System.Media;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace Jarvis;

// Everything that starts without the shortcut, plus dictation and meeting notes.
public sealed partial class Coordinator
{
    private static readonly TimeSpan FollowUpWindow = TimeSpan.FromSeconds(6), FollowUpSilence = TimeSpan.FromSeconds(1.1), FollowUpLongest = TimeSpan.FromSeconds(30);
    private const double OfferLasts = 15;
    private static readonly TimeSpan WatchEvery = TimeSpan.FromSeconds(20), RoutineCheckEvery = TimeSpan.FromSeconds(20);

    private readonly DispatcherTimer routineTimer = new(), watchTimer = new();
    private bool wasWakeEnabled, wasHindi;

    private void StartAutomation()
    {
        wakeWord.OnWake = WakeHeard;
        wakeWord.OnPartial = text => { if (isWakeCapturing) Island.Transcript = text; };
        wakeWord.OnCommand = WakeCommand;

        // Any of these can change whether the microphone should be open.
        wasWakeEnabled = Settings.Data.WakeWordEnabled;
        wasHindi = Settings.Data.HindiAssistant;
        Settings.Changed += () =>
        {
            var hindiChanged = wasHindi != Settings.Data.HindiAssistant;
            var wakeChanged = wasWakeEnabled != Settings.Data.WakeWordEnabled;
            wasHindi = Settings.Data.HindiAssistant;
            wasWakeEnabled = Settings.Data.WakeWordEnabled;
            if (wakeChanged && !Settings.Data.WakeWordEnabled)
            {
                wakeWordUpdate?.Cancel();
                wakeWord.Stop();
            }
            else if (wakeChanged || hindiChanged)
            {
                wakeWord.Stop();
                UpdateWakeWord();
            }
        };
        UpdateWakeWord();

        routineTimer.Interval = RoutineCheckEvery;
        routineTimer.Tick += (_, _) => RunDueRoutine();
        routineTimer.Start();
        watchTimer.Interval = WatchEvery;
        watchTimer.Tick += (_, _) => WatchScreen();
        watchTimer.Start();

        Island.OnAcceptOffer = () => Ask(Settings.Data.HindiAssistant
            ? "मेरी स्क्रीन पर जो समस्या दिख रही है उसे समझाइए और बताइए कि इसे कैसे ठीक करूँ।"
            : "Explain the problem showing on my screen and how to fix it.");
        Island.OnDismissOffer = Island.Rest;
    }

    private bool IsFree => mode == CompanionMode.Idle && !isListening && !isWakeCapturing && guide is null && pendingConfirmation is null;

    // MARK: Hey Jarvis

    /// <summary>The microphone stays open only while Jarvis is idle, so it can't hear itself or take over from the shortcut.</summary>
    private async void UpdateWakeWord()
    {
        wakeWordUpdate?.Cancel();
        wakeWordUpdate = null;
        if (!Settings.Data.WakeWordEnabled || meetingRecorder.IsRecording || !SpeechModel.IsInstalled)
        {
            wakeWord.Stop();
            return;
        }
        if (mode != CompanionMode.Idle)
        {
            if (!isWakeCapturing) wakeWord.Stop();
            return;
        }
        // A short wait avoids restarting between turns, and lets the end of the last word fade out of the room.
        var update = wakeWordUpdate = new CancellationTokenSource();
        try { await Task.Delay(500, update.Token); }
        catch (OperationCanceledException) { return; }
        if (!Settings.Data.WakeWordEnabled || mode != CompanionMode.Idle || isListening) return;
        try { wakeWord.Start(Settings.ListeningLanguage); }
        catch (JarvisMessage problem)
        {
            Settings.Update(d => d.WakeWordEnabled = false);
            ShowError(problem);
        }
    }

    private void WakeHeard()
    {
        if (!IsFree) return;
        isWakeCapturing = true;
        lastTurnWasVoice = true;
        SystemSounds.Beep.Play();
        Island.Rest();
        Island.Show(IslandPhase.Listening);
    }

    private void WakeCommand(string command)
    {
        if (!isWakeCapturing) return;
        isWakeCapturing = false;
        if (command.Length == 0)
        {
            Island.Rest();
            UpdateWakeWord();
            return;
        }
        Ask(command, byVoice: true);
    }

    // MARK: Follow-ups

    /// <summary>Keeps listening for a moment after a spoken reply, so they can carry on without the shortcut.</summary>
    private async void ListenForFollowUp()
    {
        if (!Settings.Data.FollowUpEnabled || !lastTurnWasVoice || actionFailure is not null || unattended || !SpeechModel.IsInstalled) return;
        wakeWordUpdate?.Cancel();
        var cancel = NewTurn();
        try
        {
            // The last word of the reply is still in the room.
            await Task.Delay(300, cancel);
            if (!IsFree) return;
            isFollowingUp = true;
            isListening = true;
            followUpHeardAt = null;
            SetMode(CompanionMode.Listening);
            Island.Transcript = "";
            Island.Show(IslandPhase.Listening);
            try { speechIn.Start(Settings.ListeningLanguage); }
            catch (JarvisMessage)
            {
                EndFollowUpQuietly();
                return;
            }

            var started = DateTime.UtcNow;
            while (true)
            {
                await Task.Delay(150, cancel);
                var now = DateTime.UtcNow;
                if (followUpHeardAt is { } heard)
                {
                    if (now - heard >= FollowUpSilence || now - started >= FollowUpLongest) break;
                }
                else if (now - started >= FollowUpWindow)
                {
                    speechIn.Cancel();
                    EndFollowUpQuietly();
                    return;
                }
            }

            isFollowingUp = false;
            isListening = false;
            Overlay.Level = 0;
            Island.Level = 0;
            var text = await speechIn.Stop();
            cancel.ThrowIfCancellationRequested();
            if (text.Length == 0 || Core.EndsConversation(text))
            {
                EndFollowUpQuietly();
                return;
            }
            StartRequest(text);
            await Perform(text, cancel);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!cancel.IsCancellationRequested) ShowError(error); }
    }

    private void EndFollowUpQuietly()
    {
        isFollowingUp = false;
        isListening = false;
        Overlay.Level = 0;
        Island.Rest();
        SetMode(CompanionMode.Idle);
    }

    // MARK: Routines

    private string? ActOnRoutine(ActionTag tag)
    {
        if (!isDirectRequest) return null;
        if (tag.Kind == "ADD_ROUTINE")
        {
            var (added, name, book) = Core.RoutineAdd(Settings.Routines.Book, tag.Value);
            if (name is null) return Report(new ActionResult("Didn't save the routine", "I couldn't work out when that routine should run."));
            if (!added) return Report(new ActionResult("Didn't save the routine", "You already have as many routines as I can keep. Delete one in Settings first."));
            Settings.Routines.Set(book);
            return Report(new ActionResult($"Saved the routine {name}"));
        }
        var (removed, remaining) = Core.RoutineRemoveNamed(Settings.Routines.Book, tag.Value);
        if (removed is null) return Report(new ActionResult($"No routine called {tag.Value}", $"You don't have a routine called {tag.Value}."));
        Settings.Routines.Set(remaining);
        return Report(new ActionResult($"Deleted the routine {removed}"));
    }

    /// <summary>
    /// A scheduled routine may run with nobody at the PC, so it never sees the screen or uses the mouse and keyboard.
    /// A routine that can't run yet is tried again until its time has passed.
    /// </summary>
    private void RunDueRoutine()
    {
        if (!IsFree || Island.Phase != IslandPhase.Resting || Island.IsOpen || Win32.IsDesktopSecure()) return;
        var (requests, book) = Core.RoutinesDue(Settings.Routines.Book);
        if (requests.Count == 0) return;
        Settings.Routines.Set(book);
        var request = requests[0];
        Interrupt();
        Island.Rest();
        lastTurnWasVoice = false;
        StartRequest(request);
        EndControl();
        unattended = true;
        _ = Perform(request, NewTurn());
    }

    // MARK: Offers of help and screen memory

    /// <summary>
    /// Reads the screen on this PC, to remember it or to offer help, if they've turned either on.
    /// Offers send nothing anywhere unless accepted, and memory stays on this PC until they ask about it.
    /// </summary>
    private async void WatchScreen()
    {
        var remembers = Settings.Data.ScreenMemoryEnabled;
        var offers = Settings.Data.ScreenWatchEnabled;
        if (!(remembers || offers) || isWatching || Win32.IsDesktopSecure()) return;
        if (ForegroundApp.Current() is not { IsJarvis: false } front || front.DisplayName.Length == 0) return;
        if (!Core.PolicyPermits(Settings.Data.AppPolicy, front.DisplayName)) return;
        // A password field being on screen is the one thing that always means leave it alone. Not knowing also counts.
        if (UIInspector.FocusIsPassword() != false) return;
        var isPrivate = Core.ScreenIsPrivate(front.DisplayName, front.Title);

        isWatching = true;
        try
        {
            var thumbnail = await ScreenCapture.Thumbnail();
            // An unchanged screen was already read, which saves the work of reading it again.
            if (thumbnail is not null && lastWatched is not null && Core.LooksSame(thumbnail, lastWatched)) return;
            lastWatched = thumbnail;
            if (await ScreenCapture.ReadText() is not { } text) return;
            if (remembers && !isPrivate) Settings.ScreenMemory.Remember(text, front.DisplayName, Settings.Data.ScreenMemoryDays);
            if (!offers || !IsFree || Island.Phase != IslandPhase.Resting || Island.IsOpen) return;
            if (Core.WatchOffer(watchRules, text) is not { } offer) return;
            Island.OfferTitle = offer;
            Island.Show(IslandPhase.Offering);
            Island.RestAfter(OfferLasts);
        }
        catch (Exception problem) { Log.Write($"Watching the screen failed: {problem.GetType().Name}"); }
        finally { isWatching = false; }
    }

    // MARK: Dictation, talking over Jarvis, and meeting notes

    private void StartVoiceFeatures()
    {
        hotkeys.DictationKey = () => Settings.Data.DictationHotkey;
        hotkeys.OnDictationPress = DictationPressed;
        hotkeys.OnDictationRelease = DictationReleased;

        bargeIn.Speaking = () => Island.Reply;
        bargeIn.OnStop = Escape;
        bargeIn.OnInterrupt = BargeHeard;
        bargeIn.OnPartial = text => { if (isBargeCapturing) Island.Transcript = text; };
        bargeIn.OnCommand = BargeCommand;

        meetingRecorder.OnLine = AddMeetingLine;
    }

    private void DictationPressed()
    {
        if (pendingConfirmation is not null) return;
        Interrupt();
        lastTurnWasVoice = false;
        isDictating = true;
        isListening = true;
        pressedAt = DateTime.UtcNow;
        Island.IsOpen = false;
        SetMode(CompanionMode.Listening);
        Island.Rest();
        Island.Show(IslandPhase.Listening);
        try { speechIn.Start(Settings.DictationLanguageCode); }
        catch (JarvisMessage problem)
        {
            isDictating = false;
            isListening = false;
            ShowError(problem);
        }
    }

    private async void DictationReleased()
    {
        if (!isDictating) return;
        isDictating = false;
        isListening = false;
        Overlay.Level = 0;
        Island.Level = 0;
        if (pressedAt is { } at && (DateTime.UtcNow - at).TotalSeconds < MinimumHold)
        {
            speechIn.Cancel();
            Island.Rest();
            SetMode(CompanionMode.Idle);
            return;
        }
        var cancel = NewTurn();
        try
        {
            var heard = await speechIn.Stop();
            cancel.ThrowIfCancellationRequested();
            var text = Core.WithoutFillers(heard);
            if (text.Length == 0)
            {
                Island.ShowMessage("Didn't catch that.", 2);
                SetMode(CompanionMode.Idle);
                return;
            }
            var finished = Settings.Data.DictationCleanup ? await CleanedUp(text, cancel) : text;
            cancel.ThrowIfCancellationRequested();
            var result = await ActionRunner.InsertDictation(finished, cancel);
            if (cancel.IsCancellationRequested) return;
            if (Settings.Data.KeepActivityLog)
            {
                // How much, rather than what. Dictation is often private, and they're looking right at it.
                var count = finished.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
                Settings.Activity.Add("Dictation", $"Dictated {count} words", result.Failure, null);
            }
            if (result.Failure is { } failure) Island.ShowMessage(failure);
            else Island.Rest();
            SetMode(CompanionMode.Idle);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!cancel.IsCancellationRequested) ShowError(error); }
    }

    /// <summary>Uses the chosen AI, and falls back to their own words if that doesn't work.</summary>
    private async Task<string> CleanedUp(string text, CancellationToken cancel)
    {
        Island.Progress = Settings.Data.HindiAssistant ? "ठीक कर रहा हूँ…" : "Cleaning that up…";
        SetMode(CompanionMode.Thinking);
        Island.Show(IslandPhase.Thinking);
        try
        {
            var cleaned = "";
            await foreach (var chunk in Settings.MakeProvider().Stream(new AIRequest(Core.CleanupSystem, text), cancel).WithCancellation(cancel)) cleaned += chunk;
            return Core.AcceptedCleanup(cleaned, text);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception problem)
        {
            Log.Write($"Cleaning up dictation failed: {problem.GetType().Name}");
            return text;
        }
    }

    /// <summary>Listens only while Jarvis has something to say, and not during a meeting, which already has the microphone.</summary>
    private void UpdateBargeIn()
    {
        if (!Settings.Data.BargeInEnabled || mode != CompanionMode.Speaking || meetingRecorder.IsRecording || !SpeechModel.IsInstalled)
        {
            if (!isBargeCapturing) bargeIn.Stop();
            return;
        }
        try { bargeIn.Start(Settings.ListeningLanguage); }
        catch (JarvisMessage problem) { Island.Notice = problem.Message; }
    }

    private void BargeHeard()
    {
        // A yes or no comes only from the shortcut or the buttons, so talking can't answer for them.
        if (pendingConfirmation is not null)
        {
            bargeIn.Stop();
            return;
        }
        // Interrupt stops this listener if it thinks it's capturing, and this one has to keep going.
        isBargeCapturing = false;
        Interrupt();
        isBargeCapturing = true;
        lastTurnWasVoice = true;
        Island.Rest();
        SetMode(CompanionMode.Listening);
        Island.Show(IslandPhase.Listening);
    }

    private void BargeCommand(string command)
    {
        if (!isBargeCapturing) return;
        isBargeCapturing = false;
        if (command.Length == 0)
        {
            Island.Rest();
            SetMode(CompanionMode.Idle);
            return;
        }
        Ask(command, byVoice: true);
    }

    public bool IsRecordingMeeting => meetingRecorder.IsRecording;

    public async void ToggleMeeting()
    {
        if (IsRecordingMeeting) await StopMeeting();
        else StartMeeting();
    }

    /// <summary>A whole sentence that starts or stops a meeting, handled here so the AI can never start a recording.</summary>
    private bool RunMeetingCommand(string transcript)
    {
        var command = Core.MeetingCommand(transcript);
        if (command is null) return false;
        DiscardPendingLook();
        Island.Rest();
        SetMode(CompanionMode.Idle);
        if (command == "start") StartMeeting();
        else _ = StopMeeting();
        return true;
    }

    private async void StartMeeting()
    {
        if (IsRecordingMeeting) return;
        // Nobody else's audio can start being processed by this while the wake word still holds the microphone.
        wakeWordUpdate?.Cancel();
        wakeWord.Stop();
        try { meetingRecorder.Start(Settings.ListeningLanguage); }
        catch (JarvisMessage problem)
        {
            Island.ShowMessage(problem.Message);
            UpdateWakeWord();
            return;
        }
        currentMeeting = new MeetingNote { Start = DateTime.Now };
        Settings.Meetings.Save(currentMeeting);
        Island.IsRecordingMeeting = true;
        OnMeetingChange(true);
        Island.ShowMessage("Taking meeting notes. Let everyone on the call know. Say \"stop meeting notes\" when you're done.", 6);
        var limit = meetingLimit = new CancellationTokenSource();
        try
        {
            await Task.Delay(LongestMeeting, limit.Token);
            await StopMeeting();
        }
        catch (OperationCanceledException) { }
    }

    private void AddMeetingLine(MeetingLine line)
    {
        if (currentMeeting is null) return;
        currentMeeting.Lines.Add(line);
        // Saved as it goes, so a crash doesn't lose the meeting.
        Settings.Meetings.Save(currentMeeting);
    }

    private async Task StopMeeting()
    {
        if (!IsRecordingMeeting) return;
        meetingLimit?.Cancel();
        meetingRecorder.Stop();
        Island.IsRecordingMeeting = false;
        OnMeetingChange(false);
        UpdateWakeWord();
        // What was still being heard is read after stopping, so this gives it a moment to arrive.
        await Task.Delay(3000);
        if (currentMeeting is not { } note) return;
        currentMeeting = null;
        note.End = DateTime.Now;
        Settings.Meetings.Save(note);
        if (note.Lines.Count == 0)
        {
            Island.ShowMessage("I didn't hear anything to take notes on.");
            Settings.Meetings.Remove(note.Id);
            return;
        }
        Island.ShowMessage("Summarizing the meeting…", 4);
        await Summarize(note);
        Island.ShowMessage("Your meeting notes are ready in Settings, under Meetings.");
    }

    /// <summary>The reply is only ever saved as text. It's never read for action tags, because the words came from a call.</summary>
    public async Task Summarize(MeetingNote note)
    {
        try
        {
            var summary = "";
            await foreach (var chunk in Settings.MakeProvider().Stream(Core.MeetingSummaryRequest(note.Transcript, Settings.Data.HindiAssistant), CancellationToken.None)) summary += chunk;
            note.Summary = summary.Trim();
            note.Problem = null;
        }
        catch (Exception problem)
        {
            note.Problem = "Couldn't summarize this: " + MessageOf(problem);
        }
        Settings.Meetings.Save(note);
    }
}
