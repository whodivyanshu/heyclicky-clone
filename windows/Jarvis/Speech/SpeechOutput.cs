using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using Windows.Media.SpeechSynthesis;

namespace Jarvis;

public abstract record VoiceConfig(bool AssistantEffect, string FallbackIdentifier, bool Hindi)
{
    public sealed record System(string Identifier, bool WantsHindi) : VoiceConfig(false, Identifier, WantsHindi);
    public sealed record Gemini(string ApiKey, string Voice, string Model, string Style, bool Effect, string Fallback, bool WantsHindi) : VoiceConfig(Effect, Fallback, WantsHindi);
    public sealed record Kokoro(int EnglishVoice, int HindiVoice, bool Effect, string Fallback, bool WantsHindi) : VoiceConfig(Effect, Fallback, WantsHindi);

    public bool UsesAudioStream => this is not System;
}

/// <summary>One piece of speech. It starts being made immediately, so its audio is ready sooner when its turn comes.</summary>
public sealed class VoiceStream
{
    private readonly Channel<byte[]> chunks = Channel.CreateUnbounded<byte[]>();
    private readonly CancellationTokenSource stop = new();

    public ChannelReader<byte[]> Chunks => chunks.Reader;

    private VoiceStream() { }

    public static VoiceStream Gemini(string text, VoiceConfig.Gemini config)
    {
        var stream = new VoiceStream();
        _ = Task.Run(() => stream.Produce(cancel => Download(text, config, stream.chunks.Writer, cancel)));
        return stream;
    }

    public static VoiceStream Kokoro(string text, VoiceConfig.Kokoro config)
    {
        var stream = new VoiceStream();
        var (voice, extra) = Core.KokoroVoiceFor(text, config.EnglishVoice, config.HindiVoice);
        _ = Task.Run(() => stream.Produce(async cancel =>
        {
            cancel.ThrowIfCancellationRequested();
            await stream.chunks.Writer.WriteAsync(await KokoroEngine.Shared.Speak(text, voice, extra), cancel);
        }));
        return stream;
    }

    private async Task Produce(Func<CancellationToken, Task> work)
    {
        try
        {
            await work(stop.Token);
            chunks.Writer.TryComplete();
        }
        catch (Exception problem) { chunks.Writer.TryComplete(problem); }
    }

    public void Cancel() => stop.Cancel();

    private static async Task Download(string text, VoiceConfig.Gemini config, ChannelWriter<byte[]> writer, CancellationToken cancel)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, Core.VoiceCatalog.Endpoint)
        {
            Content = new StringContent(Core.VoiceBody(text, config.Voice, config.Model, config.Style), Encoding.UTF8, "application/json"),
        };
        request.Headers.Add("x-goog-api-key", config.ApiKey);
        using var wait = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        wait.CancelAfter(TimeSpan.FromSeconds(20));
        using var response = await Http.Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, wait.Token);
        if (!response.IsSuccessStatusCode)
        {
            var body = await Http.Body(response, cancel);
            throw new JarvisMessage("Gemini voice: " + (Core.GeminiError(body) ?? $"HTTP {(int)response.StatusCode}"));
        }
        await foreach (var line in Http.Lines(response, TimeSpan.FromSeconds(20), cancel))
        {
            byte[]? audio;
            try { audio = Core.VoiceAudio(line); }
            catch (CoreException problem) { throw new JarvisMessage(problem.Message); }
            if (audio is not null) await writer.WriteAsync(audio, cancel);
        }
    }
}

/// <summary>Plays streamed 16-bit PCM as it arrives.</summary>
public sealed class PcmStreamPlayer : IDisposable
{
    private readonly BufferedWaveProvider buffer;
    private readonly WaveOutEvent output = new() { DesiredLatency = 150 };
    private byte? leftover;
    private bool started;
    private bool inputEnded;
    private Action? onFinished;
    private readonly System.Windows.Threading.DispatcherTimer watcher;

    /// <summary>`assistantEffect` adds a little low-end weight and a faint room, for a more synthetic assistant sound.</summary>
    public PcmStreamPlayer(int sampleRate, bool assistantEffect)
    {
        var format = new WaveFormat(sampleRate, 16, 1);
        buffer = new BufferedWaveProvider(format) { BufferDuration = TimeSpan.FromMinutes(5), ReadFully = true, DiscardOnBufferOverflow = false };
        ISampleProvider source = buffer.ToSampleProvider();
        if (assistantEffect) source = new AssistantEffect(source);
        output.Init(source);
        watcher = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
        watcher.Tick += (_, _) => CompleteIfDone();
    }

    public void Append(byte[] data)
    {
        var bytes = data;
        // A sample can be split between two network chunks.
        if (leftover is { } first)
        {
            bytes = new byte[data.Length + 1];
            bytes[0] = first;
            data.CopyTo(bytes, 1);
        }
        var length = bytes.Length;
        leftover = length % 2 == 1 ? bytes[--length] : null;
        if (length == 0) return;
        buffer.AddSamples(bytes, 0, length);
        if (!started)
        {
            started = true;
            output.Play();
        }
    }

    /// <summary>Calls `done` after everything appended so far has been heard.</summary>
    public void Finish(Action done)
    {
        onFinished = done;
        inputEnded = true;
        watcher.Start();
        CompleteIfDone();
    }

    private void CompleteIfDone()
    {
        if (!inputEnded || buffer.BufferedBytes > 0 || onFinished is null) return;
        var done = onFinished;
        onFinished = null;
        watcher.Stop();
        output.Stop();
        done();
    }

    public void Dispose()
    {
        onFinished = null;
        watcher.Stop();
        output.Stop();
        output.Dispose();
    }

    /// <summary>The same idea as the Mac's: a low shelf, a high shelf, and a faint short echo for the room.</summary>
    private sealed class AssistantEffect : ISampleProvider
    {
        private readonly ISampleProvider source;
        private readonly NAudio.Dsp.BiQuadFilter depth, clarity;
        private readonly float[] room;
        private int roomIndex;
        private const float Wet = 0.1f, Feedback = 0.25f;

        public AssistantEffect(ISampleProvider source)
        {
            this.source = source;
            var rate = source.WaveFormat.SampleRate;
            depth = NAudio.Dsp.BiQuadFilter.LowShelf(rate, 180, 1, 3);
            clarity = NAudio.Dsp.BiQuadFilter.HighShelf(rate, 4500, 1, 2);
            room = new float[rate * 45 / 1000];
        }

        public WaveFormat WaveFormat => source.WaveFormat;

        public int Read(float[] buffer, int offset, int count)
        {
            var read = source.Read(buffer, offset, count);
            for (var i = offset; i < offset + read; i++)
            {
                var sample = clarity.Transform(depth.Transform(buffer[i]));
                var echo = room[roomIndex];
                room[roomIndex] = sample + echo * Feedback;
                roomIndex = (roomIndex + 1) % room.Length;
                buffer[i] = Math.Clamp(sample + echo * Wet, -1f, 1f);
            }
            return read;
        }
    }
}

/// <summary>
/// The built-in Windows voices. They're the free, offline fallback, like the Mac voice.
/// Each piece is made in full and then played. Hindi needs a Hindi voice from Windows Settings, under Time and language, Speech.
/// </summary>
public static class WindowsVoice
{
    public sealed record VoiceRow(string Id, string Name);

    public static List<VoiceRow> BestVoices()
    {
        var language = System.Globalization.CultureInfo.CurrentUICulture.TwoLetterISOLanguageName;
        return SpeechSynthesizer.AllVoices
            .Where(v => v.Language.StartsWith(language, StringComparison.OrdinalIgnoreCase))
            .OrderBy(v => v.Language.Equals(System.Globalization.CultureInfo.CurrentUICulture.Name, StringComparison.OrdinalIgnoreCase) ? 0 : 1)
            .Select(v => new VoiceRow(v.Id, v.DisplayName))
            .ToList();
    }

    public static bool HasHindi => SpeechSynthesizer.AllVoices.Any(v => v.Language.StartsWith("hi", StringComparison.OrdinalIgnoreCase));

    private static VoiceInformation? Choose(string identifier, string text, bool hindi)
    {
        var all = SpeechSynthesizer.AllVoices;
        if (hindi || ContainsDevanagari(text))
            return all.FirstOrDefault(v => v.Language.StartsWith("hi", StringComparison.OrdinalIgnoreCase)) ?? all.FirstOrDefault(v => v.Id == identifier) ?? SpeechSynthesizer.DefaultVoice;
        return all.FirstOrDefault(v => v.Id == identifier) ?? SpeechSynthesizer.DefaultVoice;
    }

    private static bool ContainsDevanagari(string text) => text.Any(c => c is >= 'ऀ' and <= 'ॿ');

    /// <summary>Plays text, and completes when it's been heard or stopped.</summary>
    public static async Task Speak(string text, string identifier, bool hindi, CancellationToken cancel)
    {
        using var synthesizer = new SpeechSynthesizer();
        if (Choose(identifier, text, hindi) is { } voice) synthesizer.Voice = voice;
        using var stream = await synthesizer.SynthesizeTextToStreamAsync(text).AsTask(cancel);
        var bytes = new byte[stream.Size];
        await using (var source = stream.AsStreamForRead())
            await source.ReadExactlyAsync(bytes, cancel);
        cancel.ThrowIfCancellationRequested();

        using var memory = new MemoryStream(bytes);
        using var reader = new WaveFileReader(memory);
        using var output = new WaveOutEvent();
        var finished = new TaskCompletionSource();
        output.PlaybackStopped += (_, _) => finished.TrySetResult();
        output.Init(reader);
        output.Play();
        using (cancel.Register(() => output.Stop()))
            await finished.Task;
        cancel.ThrowIfCancellationRequested();
    }
}

/// <summary>
/// Plays beats in order: pointing runs when reached, and speech waits for the speech before it.
/// If a Gemini voice request fails before any sound, that text uses the Windows voice instead.
/// </summary>
public sealed class SpeechOutput
{
    /// <summary>Keeps each Gemini request a reasonable size while still sending fewer requests than one per sentence.</summary>
    private const int MaxMergedCharacters = 400;

    public Action<PointTag> OnPoint = _ => { };
    public Action<PointTag> OnTarget = _ => { };
    /// <summary>Runs an action and returns what to say instead of the model's reply if it failed. Stopping cancels it.</summary>
    public Func<ActionTag, CancellationToken, Task<string?>> OnAction = (_, _) => Task.FromResult<string?>(null);
    public Func<PointTag, CancellationToken, Task<string?>> OnClick = (_, _) => Task.FromResult<string?>(null);
    public Action OnDrained = () => { };
    public Action<string> OnVoiceError = _ => { };
    public Func<VoiceConfig> GetVoiceConfig = () => new VoiceConfig.System("", false);

    private abstract record Item
    {
        public sealed record Point(PointTag Tag) : Item;
        public sealed record Target(PointTag Tag) : Item;
        public sealed record Click(PointTag Tag) : Item;
        public sealed record Act(ActionTag Tag) : Item;
        public sealed record Say(string Text, VoiceStream? Voice) : Item;
    }

    private readonly LinkedList<Item> queue = new();
    private VoiceConfig config = new VoiceConfig.System("", false);
    private string unsentText = "";
    private bool isSpeaking, inputComplete, voiceFailedThisTurn, sentFirstSentence, dropsFurtherSpeech;
    /// <summary>Goes up on every stop, so audio that arrives late can't start playing.</summary>
    private int generation;
    private CancellationTokenSource running = new();
    private VoiceStream? currentVoice;
    private PcmStreamPlayer? player;
    private CancellationTokenSource? announcement;
    private VoiceStream? announcementVoice;
    private PcmStreamPlayer? announcementPlayer;

    public void Begin()
    {
        Stop();
        config = GetVoiceConfig();
        voiceFailedThisTurn = false;
        sentFirstSentence = false;
        dropsFurtherSpeech = false;
    }

    public void Enqueue(IEnumerable<Beat> beats)
    {
        foreach (var beat in beats)
        {
            switch (beat)
            {
                case Beat.Say say:
                    if (dropsFurtherSpeech) continue;
                    if (config.UsesAudioStream)
                    {
                        unsentText += unsentText.Length == 0 ? say.Text : " " + say.Text;
                        // The first sentence goes straight away, so the voice can start before the model has finished writing.
                        if (!sentFirstSentence || unsentText.Length >= MaxMergedCharacters)
                        {
                            sentFirstSentence = true;
                            FlushUnsentText();
                        }
                    }
                    else queue.AddLast(new Item.Say(say.Text, null));
                    break;
                case Beat.Point point:
                    FlushUnsentText();
                    queue.AddLast(new Item.Point(point.Tag));
                    break;
                case Beat.Target target:
                    FlushUnsentText();
                    queue.AddLast(new Item.Target(target.Tag));
                    break;
                case Beat.Click click:
                    FlushUnsentText();
                    queue.AddLast(new Item.Click(click.Tag));
                    break;
                case Beat.Act act:
                    FlushUnsentText();
                    queue.AddLast(new Item.Act(act.Tag));
                    break;
                // The coordinator acts on these once everything in the queue has finished.
            }
        }
        Advance();
    }

    public void FinishInput()
    {
        FlushUnsentText();
        inputComplete = true;
        Advance();
    }

    public void Stop()
    {
        generation++;
        running.Cancel();
        running = new CancellationTokenSource();
        foreach (var item in queue)
            if (item is Item.Say { Voice: { } voice }) voice.Cancel();
        queue.Clear();
        unsentText = "";
        currentVoice?.Cancel();
        currentVoice = null;
        player?.Dispose();
        player = null;
        isSpeaking = false;
        inputComplete = false;
        StopAnnouncement();
    }

    /// <summary>Says something right away, outside the queue, which stays held.</summary>
    public async void Announce(string text)
    {
        StopAnnouncement();
        var cancel = (announcement = new CancellationTokenSource()).Token;
        try
        {
            if (VoiceStreamFor(text) is { } voice)
            {
                var stream = announcementPlayer = new PcmStreamPlayer(Core.VoiceCatalog.SampleRate, config.AssistantEffect);
                announcementVoice = voice;
                var heardAny = false;
                try
                {
                    await foreach (var chunk in voice.Chunks.ReadAllAsync(cancel))
                    {
                        stream.Append(chunk);
                        heardAny = true;
                    }
                    stream.Finish(() => { });
                    return;
                }
                catch (Exception problem) when (problem is not OperationCanceledException)
                {
                    if (heardAny) return;
                }
            }
            await WindowsVoice.Speak(text, config.FallbackIdentifier, config.Hindi, cancel);
        }
        catch (OperationCanceledException) { }
        catch (Exception problem) { Log.Write($"Announcing failed: {problem.GetType().Name}"); }
    }

    public void StopAnnouncement()
    {
        announcement?.Cancel();
        announcement = null;
        announcementVoice?.Cancel();
        announcementVoice = null;
        announcementPlayer?.Dispose();
        announcementPlayer = null;
    }

    private void FlushUnsentText()
    {
        if (unsentText.Length == 0) return;
        var text = unsentText;
        unsentText = "";
        queue.AddLast(new Item.Say(text, VoiceStreamFor(text)));
    }

    private VoiceStream? VoiceStreamFor(string text)
    {
        if (voiceFailedThisTurn) return null;
        return config switch
        {
            VoiceConfig.Gemini gemini => VoiceStream.Gemini(text, gemini),
            VoiceConfig.Kokoro kokoro => VoiceStream.Kokoro(text, kokoro),
            _ => null,
        };
    }

    private void Advance()
    {
        while (!isSpeaking && queue.Count > 0)
        {
            var item = queue.First!.Value;
            queue.RemoveFirst();
            switch (item)
            {
                case Item.Point point: OnPoint(point.Tag); break;
                case Item.Target target: OnTarget(target.Tag); break;
                case Item.Click click:
                    isSpeaking = true;
                    Perform(cancel => OnClick(click.Tag, cancel));
                    break;
                case Item.Act act:
                    isSpeaking = true;
                    Perform(cancel => OnAction(act.Tag, cancel));
                    break;
                case Item.Say say:
                    isSpeaking = true;
                    if (say.Voice is not null) Play(say.Voice, say.Text);
                    else SpeakWithWindowsVoice(say.Text);
                    break;
            }
        }
        if (!isSpeaking && queue.Count == 0 && inputComplete)
        {
            inputComplete = false;
            OnDrained();
        }
    }

    /// <summary>Holds the queue until the action finishes, so speech never gets ahead of what really happened.</summary>
    private async void Perform(Func<CancellationToken, Task<string?>> work)
    {
        var started = generation;
        string? failure = null;
        try { failure = await work(running.Token); }
        catch (OperationCanceledException) { return; }
        catch (Exception problem)
        {
            // Unexpected, and nothing says it worked, so the rest of the reply shouldn't claim it did.
            Log.Write($"An action failed: {problem.GetType().Name}");
            failure = "Something went wrong, so I stopped.";
        }
        if (started != generation) return;
        if (failure is not null) ReplaceRemainingSpeech(failure);
        isSpeaking = false;
        Advance();
    }

    private void ReplaceRemainingSpeech(string text)
    {
        foreach (var item in queue.ToList())
        {
            if (item is Item.Say say)
            {
                say.Voice?.Cancel();
                queue.Remove(item);
            }
        }
        unsentText = "";
        dropsFurtherSpeech = true;
        // Empty means the reply was dropped without a word, because Jarvis is about to try another way.
        if (text.Length > 0) queue.AddFirst(new Item.Say(text, VoiceStreamFor(text)));
    }

    private async void Play(VoiceStream voice, string text)
    {
        currentVoice = voice;
        var started = generation;
        var stream = player = new PcmStreamPlayer(Core.VoiceCatalog.SampleRate, config.AssistantEffect);
        var heardAny = false;
        try
        {
            await foreach (var chunk in voice.Chunks.ReadAllAsync(running.Token))
            {
                if (started != generation) return;
                stream.Append(chunk);
                heardAny = true;
            }
            if (started != generation) return;
            if (!heardAny) throw new JarvisMessage("The voice had no audio.");
        }
        catch (OperationCanceledException) when (started != generation) { return; }
        catch (Exception problem)
        {
            if (started != generation) return;
            if (!voiceFailedThisTurn)
            {
                voiceFailedThisTurn = true;
                OnVoiceError("Using the Windows voice. " + problem.Message);
            }
            if (!heardAny)
            {
                stream.Dispose();
                player = null;
                SpeakWithWindowsVoice(text);
                return;
            }
            // Part of it played, and repeating it from the start would be worse than stopping there.
        }
        stream.Finish(() =>
        {
            if (started != generation) return;
            FinishedSpeaking();
        });
    }

    private async void SpeakWithWindowsVoice(string text)
    {
        var started = generation;
        try { await WindowsVoice.Speak(text, config.FallbackIdentifier, config.Hindi, running.Token); }
        catch (OperationCanceledException) { return; }
        catch (Exception problem)
        {
            // There's no voice left to try, so the reply stays readable on the island and the job carries on.
            Log.Write($"Speaking failed: {problem.GetType().Name}");
            if (started == generation) OnVoiceError("I couldn't speak that, because this PC's voice wouldn't play it.");
        }
        if (started == generation) FinishedSpeaking();
    }

    private void FinishedSpeaking()
    {
        isSpeaking = false;
        player?.Dispose();
        player = null;
        currentVoice = null;
        Advance();
    }
}
