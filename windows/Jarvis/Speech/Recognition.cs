using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using Whisper.net;

namespace Jarvis;

/// <summary>
/// The speech model, which runs on this PC, so no audio ever leaves it. It handles Hindi and Hindi mixed with English,
/// and isn't installed with Windows, so it's downloaded once, and refused if its checksum doesn't match.
/// </summary>
public static class SpeechModel
{
    private const string Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin";
    private const string Sha256 = "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe";
    public const int Megabytes = 148;
    public static readonly string FilePath = Path.Combine(JarvisFiles.Speech, "ggml-base.bin");

    public static bool IsInstalled => File.Exists(FilePath);
    public static event Action? Changed;
    public static string Status { get; private set; } = "";
    public static bool IsInstalling { get; private set; }

    private static void Set(string status, bool installing)
    {
        Status = status;
        IsInstalling = installing;
        Changed?.Invoke();
    }

    public static async Task Install()
    {
        if (IsInstalling || IsInstalled) return;
        Set($"Downloading the speech model, about {Megabytes} MB…", true);
        try
        {
            await Downloads.Fetch(Url, Sha256, FilePath);
            Set("", false);
        }
        catch (Exception problem) when (problem is JarvisMessage or HttpRequestException or IOException)
        {
            Set(problem is JarvisMessage ? problem.Message : "The download didn't work. Check your connection and try again.", false);
        }
    }

    private static WhisperFactory? factory;
    private static readonly object Gate = new();

    public static WhisperFactory Factory()
    {
        lock (Gate)
        {
            if (!IsInstalled) throw new JarvisMessage("The speech model isn't installed yet. Download it on the Setup page in Settings.");
            return factory ??= WhisperFactory.FromPath(FilePath);
        }
    }

    public static void Remove()
    {
        lock (Gate)
        {
            factory?.Dispose();
            factory = null;
        }
        try { File.Delete(FilePath); } catch (IOException) { }
        Changed?.Invoke();
    }
}

public static class Downloads
{
    /// <summary>Written beside the target and moved into place only once its checksum matches.</summary>
    public static async Task Fetch(string url, string sha256, string target)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        var partial = target + ".partial";
        try
        {
            using var wait = new CancellationTokenSource(TimeSpan.FromMinutes(30));
            using var response = await Http.Client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, wait.Token);
            if (!response.IsSuccessStatusCode) throw new JarvisMessage("The download didn't work. Check your connection and try again.");
            await using (var file = File.Create(partial))
                await response.Content.CopyToAsync(file, wait.Token);

            string digest;
            await using (var file = File.OpenRead(partial))
                digest = Convert.ToHexString(await SHA256.HashDataAsync(file, wait.Token));
            if (!digest.Equals(sha256, StringComparison.OrdinalIgnoreCase))
                throw new JarvisMessage("A downloaded file didn't match its checksum, so it wasn't installed.");
            File.Move(partial, target, overwrite: true);
        }
        catch (OperationCanceledException) { throw new JarvisMessage("The download took too long. Check your connection and try again."); }
        finally { try { File.Delete(partial); } catch (IOException) { } }
    }
}

/// <summary>16 kHz mono floats from the microphone or the PC's sound. The audio is held in memory and never saved.</summary>
public sealed class AudioSource : IDisposable
{
    public const int SampleRate = 16000;
    public enum Kind { Microphone, SystemSound }

    private readonly IWaveIn capture;
    private readonly BufferedWaveProvider buffer;
    private readonly ISampleProvider converted;
    private readonly float[] scratch = new float[SampleRate];

    /// <summary>Called on an audio thread with each batch of samples.</summary>
    public event Action<float[]>? Samples;

    public AudioSource(Kind kind)
    {
        try
        {
            capture = kind == Kind.SystemSound ? new WasapiLoopbackCapture() : new WasapiCapture();
            buffer = new BufferedWaveProvider(capture.WaveFormat) { DiscardOnBufferOverflow = true, ReadFully = false, BufferDuration = TimeSpan.FromSeconds(5) };
            ISampleProvider source = buffer.ToSampleProvider();
            if (source.WaveFormat.Channels > 1) source = new Downmix(source);
            converted = new NAudio.Wave.SampleProviders.WdlResamplingSampleProvider(source, SampleRate);
            capture.DataAvailable += OnData;
        }
        catch (Exception problem) when (problem is System.Runtime.InteropServices.COMException or ArgumentException or InvalidOperationException)
        {
            throw new JarvisMessage(kind == Kind.Microphone
                ? "Jarvis couldn't open the microphone. Check that one is connected and allowed for desktop apps in Windows Settings, under Privacy, Microphone."
                : "Jarvis couldn't reach this PC's sound.");
        }
    }

    public void Start()
    {
        try { capture.StartRecording(); }
        catch (Exception problem) when (problem is System.Runtime.InteropServices.COMException or InvalidOperationException)
        {
            throw new JarvisMessage("Jarvis couldn't open the microphone. Check that one is connected and allowed for desktop apps in Windows Settings, under Privacy, Microphone.");
        }
    }

    private void OnData(object? sender, WaveInEventArgs e)
    {
        buffer.AddSamples(e.Buffer, 0, e.BytesRecorded);
        int read;
        while ((read = converted.Read(scratch, 0, scratch.Length)) > 0)
            Samples?.Invoke(scratch.Take(read).ToArray());
    }

    public void Dispose()
    {
        try { capture.StopRecording(); } catch (Exception problem) when (problem is System.Runtime.InteropServices.COMException or InvalidOperationException) { }
        capture.Dispose();
    }
}

/// <summary>Averages every channel into one, because a PC's sound can be stereo or surround.</summary>
internal sealed class Downmix(ISampleProvider source) : ISampleProvider
{
    private readonly int channels = source.WaveFormat.Channels;
    private float[] scratch = Array.Empty<float>();

    public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(source.WaveFormat.SampleRate, 1);

    public int Read(float[] buffer, int offset, int count)
    {
        var wanted = count * channels;
        if (scratch.Length < wanted) scratch = new float[wanted];
        var frames = source.Read(scratch, 0, wanted) / channels;
        for (var frame = 0; frame < frames; frame++)
        {
            var sum = 0f;
            for (var channel = 0; channel < channels; channel++) sum += scratch[frame * channels + channel];
            buffer[offset + frame] = sum / channels;
        }
        return frames;
    }
}

/// <summary>
/// Turns audio into text as it's spoken, on this PC. Whisper isn't a streaming recognizer, so what's been heard so far
/// is read again every moment, and reported as the current text. Long stretches are finished off so reading stays quick.
/// </summary>
public sealed class Transcriber : IDisposable
{
    private const double PartialEverySeconds = 1.2;
    /// <summary>After this much audio, what's been heard is kept and reading starts again from there.</summary>
    private const int MaxWindowSeconds = 20;
    private const float SilenceRms = 0.008f;
    private const int KeepAfterSilence = 1;

    private readonly string language;
    private readonly List<float> window = new();
    private readonly object gate = new();
    private readonly CancellationTokenSource stop = new();
    private readonly Task loop;
    private readonly SemaphoreSlim reading = new(1, 1);
    private string finished = "";
    private string current = "";
    private bool changed;

    /// <summary>The whole text so far. Called on a worker thread.</summary>
    public event Action<string>? Text;

    public Transcriber(string? language)
    {
        this.language = language ?? "auto";
        loop = Task.Run(Run);
    }

    public void Append(float[] samples)
    {
        lock (gate)
        {
            window.AddRange(samples);
            changed = true;
        }
    }

    private async Task Run()
    {
        try
        {
            while (!stop.IsCancellationRequested)
            {
                await Task.Delay(TimeSpan.FromSeconds(PartialEverySeconds), stop.Token);
                await ReadOnce(stop.Token);
            }
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>Silent only if every tenth of a second is, so one quiet word in a long pause still counts as speech.</summary>
    private static bool IsSilent(float[] samples)
    {
        var frame = AudioSource.SampleRate / 10;
        for (var start = 0; start < samples.Length; start += frame)
        {
            var end = Math.Min(start + frame, samples.Length);
            double sum = 0;
            for (var i = start; i < end; i++) sum += samples[i] * samples[i];
            if (Math.Sqrt(sum / (end - start)) >= SilenceRms) return false;
        }
        return true;
    }

    private async Task ReadOnce(CancellationToken cancel)
    {
        float[] samples;
        var rollOver = false;
        lock (gate)
        {
            if (!changed) return;
            changed = false;
            samples = window.ToArray();
            rollOver = samples.Length > MaxWindowSeconds * AudioSource.SampleRate;
        }
        // Whisper invents words for silence, so silence isn't read at all. What's been heard so far is kept, and the
        // silence is let go, so listening for hours doesn't keep hours of audio or take longer to read.
        if (IsSilent(samples))
        {
            lock (gate)
            {
                if (window.Count > KeepAfterSilence * AudioSource.SampleRate)
                {
                    finished = Join(finished, current);
                    current = "";
                    window.RemoveRange(0, window.Count - KeepAfterSilence * AudioSource.SampleRate);
                }
            }
            return;
        }
        await reading.WaitAsync(cancel);
        try
        {
            var text = await Transcribe(samples, cancel);
            lock (gate)
            {
                current = text;
                if (rollOver)
                {
                    finished = Join(finished, current);
                    current = "";
                    window.RemoveRange(0, Math.Min(samples.Length, window.Count));
                }
            }
            Text?.Invoke(Whole());
        }
        catch (Exception problem) when (problem is not OperationCanceledException)
        {
            Log.Write($"Recognition failed: {problem.GetType().Name}");
        }
        finally { reading.Release(); }
    }

    private async Task<string> Transcribe(float[] samples, CancellationToken cancel)
    {
        using var processor = SpeechModel.Factory().CreateBuilder().WithLanguage(language).Build();
        var parts = new List<string>();
        await foreach (var segment in processor.ProcessAsync(samples, cancel)) parts.Add(segment.Text);
        return Cleaned(string.Concat(parts));
    }

    /// <summary>Whisper marks non-speech in brackets, such as [BLANK_AUDIO] or (music), which nobody said.</summary>
    private static string Cleaned(string text)
    {
        var withoutMarks = System.Text.RegularExpressions.Regex.Replace(text, @"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*", " ");
        return System.Text.RegularExpressions.Regex.Replace(withoutMarks, @"\s+", " ").Trim();
    }

    private static string Join(string a, string b) => a.Length == 0 ? b : b.Length == 0 ? a : a + " " + b;

    private string Whole()
    {
        lock (gate) return Join(finished, current);
    }

    /// <summary>Reads whatever is left, and returns the final text.</summary>
    public async Task<string> Finish()
    {
        stop.Cancel();
        try { await loop; } catch (OperationCanceledException) { }
        await reading.WaitAsync();
        try
        {
            float[] samples;
            lock (gate) samples = window.ToArray();
            if (IsSilent(samples)) return Whole();
            var text = await Transcribe(samples, CancellationToken.None);
            lock (gate) current = text;
            return Whole();
        }
        catch (JarvisMessage) { throw; }
        catch (Exception problem)
        {
            Log.Write($"Recognition failed: {problem.GetType().Name}");
            return Whole();
        }
        finally { reading.Release(); }
    }

    public void Dispose()
    {
        stop.Cancel();
    }
}

/// <summary>Hold-to-talk: opens the microphone, and returns the text when it's let go.</summary>
public sealed class SpeechInput
{
    public Action<float> OnLevel = _ => { };
    public Action<string> OnPartial = _ => { };

    private AudioSource? audio;
    private Transcriber? transcriber;
    private readonly System.Windows.Threading.Dispatcher ui = System.Windows.Threading.Dispatcher.CurrentDispatcher;

    public void Start(string? language)
    {
        Cancel();
        // Checked now, so they find out before talking rather than after.
        SpeechModel.Factory();
        var source = new AudioSource(AudioSource.Kind.Microphone);
        var reader = new Transcriber(language);
        source.Samples += samples =>
        {
            reader.Append(samples);
            double sum = 0;
            foreach (var s in samples) sum += s * s;
            var level = (float)Math.Min(1, Math.Sqrt(sum / samples.Length) * 8);
            ui.BeginInvoke(() => OnLevel(level));
        };
        reader.Text += text => ui.BeginInvoke(() => { if (transcriber == reader) OnPartial(text); });
        audio = source;
        transcriber = reader;
        source.Start();
    }

    public async Task<string> Stop()
    {
        audio?.Dispose();
        audio = null;
        var reader = transcriber;
        transcriber = null;
        return reader is null ? "" : await reader.Finish();
    }

    public void Cancel()
    {
        audio?.Dispose();
        audio = null;
        transcriber?.Dispose();
        transcriber = null;
    }
}

/// <summary>
/// Listening that keeps going while Jarvis is idle or talking. Everything stays on this PC. The heard text starts again
/// every so often, so it never grows without limit, unless `CanRenew` says a request is partway through.
/// </summary>
public sealed class ContinuousRecognition
{
    private const int RenewAfterSeconds = 30;

    public Action<string> OnText = _ => { };
    public Func<bool> CanRenew = () => true;
    /// <summary>Called with what was heard when a stretch of listening ends.</summary>
    public Action<string> OnSessionEnd = _ => { };

    private readonly AudioSource.Kind kind;
    private readonly System.Windows.Threading.Dispatcher ui = System.Windows.Threading.Dispatcher.CurrentDispatcher;
    private AudioSource? audio;
    private Transcriber? reader;
    private string language = "auto";
    private string lastText = "";
    private DateTime started;
    private int generation;

    public ContinuousRecognition(AudioSource.Kind kind = AudioSource.Kind.Microphone) => this.kind = kind;

    public bool IsRunning => audio is not null;

    public void Start(string? language)
    {
        if (IsRunning) return;
        SpeechModel.Factory();
        this.language = language ?? "auto";
        var source = new AudioSource(kind);
        source.Samples += samples => reader?.Append(samples);
        audio = source;
        BeginStretch();
        source.Start();
    }

    private void BeginStretch()
    {
        var mine = ++generation;
        var next = new Transcriber(language == "auto" ? null : language);
        next.Text += text => ui.BeginInvoke(() =>
        {
            if (mine != generation) return;
            lastText = text;
            OnText(text);
            if ((DateTime.UtcNow - started).TotalSeconds > RenewAfterSeconds && CanRenew()) Renew();
        });
        lastText = "";
        started = DateTime.UtcNow;
        reader = next;
    }

    private void Renew()
    {
        var finished = lastText;
        reader?.Dispose();
        BeginStretch();
        OnSessionEnd(finished);
    }

    /// <summary>With `flush`, what was still being heard is read and reported before stopping.</summary>
    public async void Stop(bool flush = false)
    {
        var source = audio;
        var last = reader;
        audio = null;
        reader = null;
        generation++;
        source?.Dispose();
        if (last is null) return;
        if (!flush)
        {
            last.Dispose();
            return;
        }
        var text = await last.Finish();
        OnSessionEnd(text);
    }

    public void Append(float[] samples) => reader?.Append(samples);
}

/// <summary>Listens for "hey Jarvis" on this PC, so no audio leaves it while it waits.</summary>
public sealed class WakeWordListener
{
    private static readonly TimeSpan SilenceAfterCommand = TimeSpan.FromSeconds(1.2), WaitForCommand = TimeSpan.FromSeconds(5), LongestCommand = TimeSpan.FromSeconds(30);

    public Action OnWake = () => { };
    public Action<string> OnPartial = _ => { };
    public Action<string> OnCommand = _ => { };

    private readonly ContinuousRecognition recognition = new();
    private CancellationTokenSource? capture;
    private string? command;
    private DateTime lastChange, wokeAt;

    public WakeWordListener()
    {
        recognition.OnText = Heard;
        recognition.OnSessionEnd = _ => { if (command is not null) Finish(); };
        // Never cut someone off partway through a request.
        recognition.CanRenew = () => command is null;
    }

    public void Start(string? language) => recognition.Start(language);

    public void Stop()
    {
        capture?.Cancel();
        capture = null;
        command = null;
        recognition.Stop();
    }

    private void Heard(string text)
    {
        if (Core.WakeCommand(text) is not { } words) return;
        if (command is null)
        {
            wokeAt = DateTime.UtcNow;
            lastChange = wokeAt;
            command = words;
            OnWake();
            WatchForEnd();
        }
        else if (words != command)
        {
            command = words;
            lastChange = DateTime.UtcNow;
        }
        OnPartial(words);
    }

    private async void WatchForEnd()
    {
        capture?.Cancel();
        var cancel = (capture = new CancellationTokenSource()).Token;
        try
        {
            while (true)
            {
                await Task.Delay(150, cancel);
                if (command is null) return;
                var now = DateTime.UtcNow;
                var waited = now - lastChange;
                if ((command.Length == 0 ? waited >= WaitForCommand : waited >= SilenceAfterCommand) || now - wokeAt >= LongestCommand)
                {
                    Finish();
                    return;
                }
            }
        }
        catch (OperationCanceledException) { }
    }

    private void Finish()
    {
        var heard = command ?? "";
        Stop();
        OnCommand(heard);
    }
}

/// <summary>Listens while Jarvis is talking, to notice them talking over it. Everything stays on this PC.</summary>
public sealed class BargeInListener
{
    private static readonly TimeSpan SilenceAfterCommand = TimeSpan.FromSeconds(1.1), LongestCommand = TimeSpan.FromSeconds(30);

    public Func<string> Speaking = () => "";
    public Action OnStop = () => { };
    public Action OnInterrupt = () => { };
    public Action<string> OnPartial = _ => { };
    public Action<string> OnCommand = _ => { };

    private readonly ContinuousRecognition recognition = new();
    private CancellationTokenSource? capture;
    private int? startIndex;
    private string heardText = "";
    private DateTime lastChange;

    public BargeInListener()
    {
        recognition.OnText = Heard;
        recognition.OnSessionEnd = _ => { if (startIndex is not null) Finish(); };
        recognition.CanRenew = () => startIndex is null;
    }

    public void Start(string? language) => recognition.Start(language);

    public void Stop()
    {
        capture?.Cancel();
        capture = null;
        startIndex = null;
        heardText = "";
        recognition.Stop();
    }

    private void Heard(string text)
    {
        if (startIndex is { } start)
        {
            if (text != heardText)
            {
                heardText = text;
                lastChange = DateTime.UtcNow;
                OnPartial(Core.BargeRequest(text, start));
            }
            return;
        }
        if (Core.BargeInterruption(text, Speaking()) is not { } interruption) return;
        if (interruption.IsStop)
        {
            Stop();
            OnStop();
            return;
        }
        startIndex = interruption.StartingAt;
        heardText = text;
        lastChange = DateTime.UtcNow;
        OnInterrupt();
        OnPartial(interruption.Text);
        WatchForEnd();
    }

    private async void WatchForEnd()
    {
        var started = DateTime.UtcNow;
        capture?.Cancel();
        var cancel = (capture = new CancellationTokenSource()).Token;
        try
        {
            while (true)
            {
                await Task.Delay(150, cancel);
                var now = DateTime.UtcNow;
                if (now - lastChange >= SilenceAfterCommand || now - started >= LongestCommand)
                {
                    Finish();
                    return;
                }
            }
        }
        catch (OperationCanceledException) { }
    }

    private void Finish()
    {
        var command = startIndex is { } start ? Core.BargeRequest(heardText, start) : "";
        Stop();
        OnCommand(command);
    }
}

/// <summary>Turns your microphone and the PC's sound into a transcript, on this PC. The audio itself is never saved.</summary>
public sealed class MeetingRecorder
{
    public Action<MeetingLine> OnLine = _ => { };
    public bool IsRecording { get; private set; }

    private readonly ContinuousRecognition microphone = new(AudioSource.Kind.Microphone);
    private readonly ContinuousRecognition systemSound = new(AudioSource.Kind.SystemSound);

    public void Start(string? language)
    {
        if (IsRecording) return;
        microphone.OnSessionEnd = text => Commit(text, "Me");
        systemSound.OnSessionEnd = text => Commit(text, "Others");
        systemSound.Start(language);
        try { microphone.Start(language); }
        catch
        {
            systemSound.Stop();
            throw;
        }
        IsRecording = true;
    }

    public void Stop()
    {
        if (!IsRecording) return;
        IsRecording = false;
        microphone.Stop(flush: true);
        systemSound.Stop(flush: true);
    }

    private void Commit(string text, string speaker)
    {
        var trimmed = text.Trim();
        if (trimmed.Length > 0) OnLine(new MeetingLine { Speaker = speaker, Text = trimmed, Date = DateTime.Now });
    }
}
