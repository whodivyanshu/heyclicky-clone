using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Jarvis;

public static class KokoroFiles
{
    public static readonly string Runtime = Path.Combine(JarvisFiles.Kokoro, "runtime");
    public static string Model => Path.Combine(JarvisFiles.Kokoro, Core.KokoroCatalog.ModelFolder);
    private static readonly string Marker = Path.Combine(JarvisFiles.Kokoro, "installed");

    /// <summary>Written last, so a download that was cut short never counts.</summary>
    public static bool IsInstalled => File.Exists(Marker);
    public static void MarkInstalled() => File.WriteAllBytes(Marker, Array.Empty<byte>());
    public static void Remove()
    {
        try { Directory.Delete(JarvisFiles.Kokoro, recursive: true); }
        catch (Exception problem) when (problem is DirectoryNotFoundException) { }
    }
}

/// <summary>Downloads Kokoro only when asked, and refuses anything whose checksum doesn't match.</summary>
public sealed class KokoroInstaller
{
    public static readonly KokoroInstaller Shared = new();
    public string Status { get; private set; } = "";
    public string Problem { get; private set; } = "";
    public bool IsWorking { get; private set; }
    public event Action? Changed;

    private void Set(string status, string problem = "", bool working = true)
    {
        Status = status;
        Problem = problem;
        IsWorking = working;
        Changed?.Invoke();
    }

    public async void Install()
    {
        if (IsWorking) return;
        var catalog = Core.KokoroCatalog;
        var folder = Path.Combine(Path.GetTempPath(), "jarvis-kokoro-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(folder);
            var runtime = Path.Combine(folder, "runtime.tar.bz2");
            var model = Path.Combine(folder, "model.tar.bz2");
            Set("Downloading the voice engine…");
            await Downloads.Fetch(catalog.Runtime.Url, catalog.Runtime.Sha256, runtime);
            Set($"Downloading the voices, about {catalog.Model.Megabytes} MB…");
            await Downloads.Fetch(catalog.Model.Url, catalog.Model.Sha256, model);
            Set("Unpacking…");
            await Task.Run(() =>
            {
                KokoroFiles.Remove();
                Directory.CreateDirectory(KokoroFiles.Runtime);
                // Only the libraries. The archive also holds programs Jarvis has no use for.
                Unpack(runtime, KokoroFiles.Runtime, "--strip-components", "1", "*/lib/*");
                Unpack(model, JarvisFiles.Kokoro);
            });
            KokoroFiles.MarkInstalled();
            Set("", working: false);
        }
        catch (Exception problem) when (problem is JarvisMessage or System.Net.Http.HttpRequestException or IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            KokoroFiles.Remove();
            Set("", problem is JarvisMessage ? problem.Message : "The download didn't work. Check your connection and try again.", working: false);
        }
        finally
        {
            try { Directory.Delete(folder, recursive: true); } catch (IOException) { }
        }
    }

    public void Remove()
    {
        KokoroEngine.Shared.Unload();
        KokoroFiles.Remove();
        Set("", working: false);
    }

    /// <summary>Windows 10 and later come with tar, which reads these archives.</summary>
    private static void Unpack(string archive, string folder, params string[] arguments)
    {
        var start = new ProcessStartInfo { FileName = Path.Combine(Environment.SystemDirectory, "tar.exe"), UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (var argument in new[] { "-xjf", archive, "-C", folder }.Concat(arguments)) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        process.OutputDataReceived += (_, _) => { };
        process.ErrorDataReceived += (_, _) => { };
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        process.WaitForExit();
        if (process.ExitCode != 0) throw new JarvisMessage("The download couldn't be unpacked.");
    }
}

/// <summary>
/// Runs Kokoro inside Jarvis. The library is loaded the first time this voice speaks, and the model is let go after a
/// quiet spell, because it takes a few hundred MB of memory. It's reached through its C API, as on the Mac.
/// </summary>
public sealed class KokoroEngine
{
    public static readonly KokoroEngine Shared = new();

    private static readonly TimeSpan IdleLimit = TimeSpan.FromMinutes(5);
    private const int Threads = 4;

    // Field for field from Sources/CSherpaOnnx/include/CSherpaOnnx.h, which is copied from sherpa-onnx 1.13.8.
    // The layout has to match that library, and the catalog pins that exact version by checksum.
    [StructLayout(LayoutKind.Sequential)]
    private struct VitsConfig { public IntPtr Model, Lexicon, Tokens, DataDir; public float NoiseScale, NoiseScaleW, LengthScale; public IntPtr DictDir; }
    [StructLayout(LayoutKind.Sequential)]
    private struct MatchaConfig { public IntPtr AcousticModel, Vocoder, Lexicon, Tokens, DataDir; public float NoiseScale, LengthScale; public IntPtr DictDir; }
    [StructLayout(LayoutKind.Sequential)]
    private struct KokoroConfig { public IntPtr Model, Voices, Tokens, DataDir; public float LengthScale; public IntPtr DictDir, Lexicon, Lang; }
    [StructLayout(LayoutKind.Sequential)]
    private struct KittenConfig { public IntPtr Model, Voices, Tokens, DataDir; public float LengthScale; }
    [StructLayout(LayoutKind.Sequential)]
    private struct ZipvoiceConfig { public IntPtr Tokens, Encoder, Decoder, Vocoder, DataDir, Lexicon; public float FeatScale, TShift, TargetRms, GuidanceScale; }
    [StructLayout(LayoutKind.Sequential)]
    private struct PocketConfig { public IntPtr LmFlow, LmMain, Encoder, Decoder, TextConditioner, VocabJson, TokenScoresJson; public int VoiceEmbeddingCacheCapacity; }
    [StructLayout(LayoutKind.Sequential)]
    private struct SupertonicConfig { public IntPtr DurationPredictor, TextEncoder, VectorEstimator, Vocoder, TtsJson, UnicodeIndexer, VoiceStyle; }
    [StructLayout(LayoutKind.Sequential)]
    private struct ModelConfig
    {
        public VitsConfig Vits;
        public int NumThreads, Debug;
        public IntPtr Provider;
        public MatchaConfig Matcha;
        public KokoroConfig Kokoro;
        public KittenConfig Kitten;
        public ZipvoiceConfig Zipvoice;
        public PocketConfig Pocket;
        public SupertonicConfig Supertonic;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct TtsConfig { public ModelConfig Model; public IntPtr RuleFsts; public int MaxNumSentences; public IntPtr RuleFars; public float SilenceScale; }
    [StructLayout(LayoutKind.Sequential)]
    private struct GeneratedAudio { public IntPtr Samples; public int N, SampleRate; }
    [StructLayout(LayoutKind.Sequential)]
    private struct GenerationConfig
    {
        public float SilenceScale, Speed;
        public int Sid;
        public IntPtr ReferenceAudio;
        public int ReferenceAudioLen, ReferenceSampleRate;
        public IntPtr ReferenceText;
        public int NumSteps;
        public IntPtr Extra;
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate IntPtr CreateFn(IntPtr config);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void DestroyFn(IntPtr engine);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate IntPtr GenerateFn(IntPtr engine, byte[] text, IntPtr config, IntPtr callback, IntPtr argument);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void DestroyAudioFn(IntPtr audio);

    private readonly SemaphoreSlim one = new(1, 1);
    private IntPtr library, engine;
    private CreateFn? create;
    private DestroyFn? destroy;
    private GenerateFn? generate;
    private DestroyAudioFn? destroyAudio;
    private DateTime lastUsed;

    private void LoadLibrary()
    {
        if (library != IntPtr.Zero) return;
        var folder = Path.Combine(KokoroFiles.Runtime, "lib");
        // It finds the ONNX runtime beside itself.
        if (!NativeLibrary.TryLoad(Path.Combine(folder, "sherpa-onnx-c-api.dll"), typeof(KokoroEngine).Assembly, DllImportSearchPath.UseDllDirectoryForDependencies | DllImportSearchPath.AssemblyDirectory, out var handle))
            throw new JarvisMessage("Kokoro couldn't load. Remove it in Settings and install it again.");
        T Symbol<T>(string name) where T : Delegate
        {
            if (!NativeLibrary.TryGetExport(handle, name, out var address)) throw new JarvisMessage($"Kokoro is missing {name}. Remove it in Settings and install it again.");
            return Marshal.GetDelegateForFunctionPointer<T>(address);
        }
        create = Symbol<CreateFn>("SherpaOnnxCreateOfflineTts");
        destroy = Symbol<DestroyFn>("SherpaOnnxDestroyOfflineTts");
        generate = Symbol<GenerateFn>("SherpaOnnxOfflineTtsGenerateWithConfig");
        destroyAudio = Symbol<DestroyAudioFn>("SherpaOnnxDestroyOfflineTtsGeneratedAudio");
        library = handle;
    }

    /// <summary>Makes speech for this text, and returns it as 16-bit samples at 24,000 Hz.</summary>
    public async Task<byte[]> Speak(string text, int voice, string? extra)
    {
        await one.WaitAsync();
        try
        {
            return await Task.Run(() => SpeakNow(text, voice, extra));
        }
        finally
        {
            lastUsed = DateTime.UtcNow;
            one.Release();
            _ = UnloadWhenIdle();
        }
    }

    private byte[] SpeakNow(string text, int voice, string? extra)
    {
        if (!KokoroFiles.IsInstalled) throw new JarvisMessage("Kokoro isn't installed yet.");
        LoadLibrary();
        if (engine == IntPtr.Zero) engine = CreateEngine();

        var generation = new GenerationConfig { Speed = 1, Sid = voice, SilenceScale = 0.2f };
        var extraText = extra is null ? IntPtr.Zero : Marshal.StringToCoTaskMemUTF8(extra);
        generation.Extra = extraText;
        var configMemory = Marshal.AllocCoTaskMem(Marshal.SizeOf<GenerationConfig>());
        try
        {
            Marshal.StructureToPtr(generation, configMemory, false);
            var audio = generate!(engine, Encoding.UTF8.GetBytes(text + "\0"), configMemory, IntPtr.Zero, IntPtr.Zero);
            if (audio == IntPtr.Zero) throw new JarvisMessage("Kokoro couldn't read that text.");
            try
            {
                var result = Marshal.PtrToStructure<GeneratedAudio>(audio);
                if (result.N <= 0 || result.Samples == IntPtr.Zero) throw new JarvisMessage("Kokoro couldn't read that text.");
                var samples = new float[result.N];
                Marshal.Copy(result.Samples, samples, 0, result.N);
                var pcm = new byte[result.N * 2];
                for (var i = 0; i < samples.Length; i++)
                {
                    var value = (short)Math.Round(Math.Clamp(samples[i], -1f, 1f) * 32767);
                    pcm[i * 2] = (byte)value;
                    pcm[i * 2 + 1] = (byte)(value >> 8);
                }
                return pcm;
            }
            finally { destroyAudio!(audio); }
        }
        finally
        {
            Marshal.FreeCoTaskMem(configMemory);
            if (extraText != IntPtr.Zero) Marshal.FreeCoTaskMem(extraText);
        }
    }

    private IntPtr CreateEngine()
    {
        var strings = new List<IntPtr>();
        IntPtr Text(string value)
        {
            var pointer = Marshal.StringToCoTaskMemUTF8(value);
            strings.Add(pointer);
            return pointer;
        }
        string InModel(string name) => Path.Combine(KokoroFiles.Model, name);

        var config = new TtsConfig { MaxNumSentences = 1, SilenceScale = 0.2f };
        config.Model.NumThreads = Threads;
        config.Model.Provider = Text("cpu");
        config.Model.Kokoro = new KokoroConfig
        {
            Model = Text(InModel("model.int8.onnx")),
            Voices = Text(InModel("voices.bin")),
            Tokens = Text(InModel("tokens.txt")),
            DataDir = Text(InModel("espeak-ng-data")),
            DictDir = Text(InModel("dict")),
            Lexicon = Text(InModel("lexicon-us-en.txt") + "," + InModel("lexicon-zh.txt")),
            LengthScale = 1,
        };
        var memory = Marshal.AllocCoTaskMem(Marshal.SizeOf<TtsConfig>());
        try
        {
            Marshal.StructureToPtr(config, memory, false);
            var created = create!(memory);
            return created != IntPtr.Zero ? created : throw new JarvisMessage("Kokoro couldn't start. Remove it in Settings and install it again.");
        }
        finally
        {
            Marshal.FreeCoTaskMem(memory);
            foreach (var pointer in strings) Marshal.FreeCoTaskMem(pointer);
        }
    }

    private async Task UnloadWhenIdle()
    {
        await Task.Delay(IdleLimit + TimeSpan.FromSeconds(1));
        if (DateTime.UtcNow - lastUsed >= IdleLimit) Unload();
    }

    /// <summary>Lets go of the model. The library stays, because it can't be safely unloaded from a running app.</summary>
    public void Unload()
    {
        one.Wait();
        try
        {
            if (engine != IntPtr.Zero) destroy?.Invoke(engine);
            engine = IntPtr.Zero;
        }
        finally { one.Release(); }
    }

}
