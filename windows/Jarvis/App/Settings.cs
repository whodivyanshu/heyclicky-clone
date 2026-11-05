using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Jarvis;

public enum ProviderChoice { ClaudeCode, Gemini, Ollama }
public enum VoiceEngine { System, Gemini, Kokoro }
public enum HotkeyChoice { ControlAlt, ControlWin, AltWin }
public enum DictationHotkey { Off, ControlShift, AltShift }
public enum DictationLanguage { System, Hindi }

public static class HotkeyInfo
{
    public static string Title(this HotkeyChoice key) => key switch
    {
        HotkeyChoice.ControlAlt => "Ctrl + Alt",
        HotkeyChoice.ControlWin => "Ctrl + Win",
        _ => "Alt + Win",
    };

    public static string Title(this DictationHotkey key) => key switch
    {
        DictationHotkey.ControlShift => "Ctrl + Shift",
        DictationHotkey.AltShift => "Alt + Shift",
        _ => "Off",
    };

    public static int[] Keys(this HotkeyChoice key) => key switch
    {
        HotkeyChoice.ControlAlt => new[] { Win32.VK_CONTROL, Win32.VK_MENU },
        HotkeyChoice.ControlWin => new[] { Win32.VK_CONTROL, -1 },
        _ => new[] { Win32.VK_MENU, -1 },
    };

    public static int[]? Keys(this DictationHotkey key) => key switch
    {
        DictationHotkey.ControlShift => new[] { Win32.VK_CONTROL, Win32.VK_SHIFT },
        DictationHotkey.AltShift => new[] { Win32.VK_MENU, Win32.VK_SHIFT },
        _ => null,
    };
}

public sealed class AppPolicy
{
    public bool OnlyAllowed { get; set; }
    public List<string> Allowed { get; set; } = new();
    public List<string> Blocked { get; set; } = new();
}

/// <summary>Where Jarvis keeps its files. %LOCALAPPDATA% is only readable by this user and administrators.</summary>
public static class JarvisFiles
{
    public static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Jarvis");
    public static readonly string Screenshots = Path.Combine(Folder, "Activity screenshots");
    public static readonly string TeachingPacks = Path.Combine(Folder, "Teaching packs");
    public static readonly string Speech = Path.Combine(Folder, "Speech");
    public static readonly string Kokoro = Path.Combine(Folder, "Kokoro");

    public static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = false,
        Converters = { new JsonStringEnumConverter() },
    };

    public static T? Load<T>(string name) where T : class
    {
        try { return JsonSerializer.Deserialize<T>(File.ReadAllText(Path.Combine(Folder, name)), Json); }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
        catch (Exception problem)
        {
            // A damaged file is set aside rather than overwritten, in case it can be recovered.
            Log.Write($"Couldn't read {name}: {problem.GetType().Name}");
            try { File.Move(Path.Combine(Folder, name), Path.Combine(Folder, name + ".damaged"), overwrite: true); } catch { }
            return null;
        }
    }

    public static void Save<T>(T value, string name) => WriteAllBytes(Path.Combine(Folder, name), JsonSerializer.SerializeToUtf8Bytes(value, Json));

    /// <summary>Written beside the target and swapped in, so a crash can't leave half a file.</summary>
    public static void WriteAllBytes(string path, byte[] data)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temporary = path + ".tmp";
            File.WriteAllBytes(temporary, data);
            File.Move(temporary, path, overwrite: true);
        }
        catch (Exception problem) { Log.Write($"Couldn't save {Path.GetFileName(path)}: {problem.GetType().Name}"); }
    }
}

/// <summary>Stage names and failures only, never what anyone said or what was on screen.</summary>
public static class Log
{
    private static readonly object Gate = new();
    private static readonly string FilePath = Path.Combine(JarvisFiles.Folder, "jarvis.log");

    public static void Write(string line)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(JarvisFiles.Folder);
                var info = new FileInfo(FilePath);
                if (info.Exists && info.Length > 1_000_000) File.Move(FilePath, FilePath + ".old", overwrite: true);
                File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {line}{Environment.NewLine}");
            }
        }
        catch { }
    }
}

/// <summary>The Gemini key, encrypted with DPAPI so only this Windows account can read it.</summary>
public static class Secrets
{
    private static readonly string FilePath = Path.Combine(JarvisFiles.Folder, "gemini.key");
    private static readonly byte[] Purpose = Encoding.UTF8.GetBytes("local.jarvis.gemini-api-key");

    public static string? GeminiKey
    {
        get
        {
            try
            {
                var bytes = ProtectedData.Unprotect(File.ReadAllBytes(FilePath), Purpose, DataProtectionScope.CurrentUser);
                var key = Encoding.UTF8.GetString(bytes);
                return key.Length == 0 ? null : key;
            }
            catch { return null; }
        }
    }

    public static bool SetGeminiKey(string key)
    {
        try
        {
            if (key.Length == 0)
            {
                File.Delete(FilePath);
                return true;
            }
            Directory.CreateDirectory(JarvisFiles.Folder);
            File.WriteAllBytes(FilePath, ProtectedData.Protect(Encoding.UTF8.GetBytes(key), Purpose, DataProtectionScope.CurrentUser));
            return true;
        }
        catch { return false; }
    }
}

/// <summary>Saved choices, with the same defaults as the Mac app. Everything that listens or watches by itself starts off.</summary>
public sealed class SettingsData
{
    public bool Onboarded { get; set; }
    public ProviderChoice Provider { get; set; } = ProviderChoice.ClaudeCode;
    public HotkeyChoice Hotkey { get; set; } = HotkeyChoice.ControlAlt;
    public string ClaudeModel { get; set; } = AppSettings.DefaultClaudeModel;
    public string GeminiModel { get; set; } = AppSettings.DefaultGeminiModel;
    public string VoiceIdentifier { get; set; } = "";
    public bool ShowWhenIdle { get; set; } = true;
    public bool ShowIslandWhenIdle { get; set; } = true;
    public bool ControlsPC { get; set; }
    public VoiceEngine? VoiceEngine { get; set; }
    public int? KokoroEnglishVoice { get; set; }
    public int? KokoroHindiVoice { get; set; }
    public string? GeminiVoice { get; set; }
    public string? GeminiVoiceModel { get; set; }
    public bool HindiAssistant { get; set; }
    public string OllamaModel { get; set; } = "";
    public bool WakeWordEnabled { get; set; }
    public bool FollowUpEnabled { get; set; }
    public bool ScreenWatchEnabled { get; set; }
    public bool SaveConversations { get; set; } = true;
    public bool KeepActivityLog { get; set; } = true;
    public bool KeepActivityScreenshots { get; set; }
    public AppPolicy AppPolicy { get; set; } = new();
    public DictationHotkey DictationHotkey { get; set; } = DictationHotkey.Off;
    public DictationLanguage DictationLanguage { get; set; } = DictationLanguage.System;
    public bool DictationCleanup { get; set; }
    public bool BargeInEnabled { get; set; }
    public bool TeachingEnabled { get; set; } = true;
    public bool ScreenMemoryEnabled { get; set; }
    public int ScreenMemoryDays { get; set; } = 7;
}

public sealed class AppSettings
{
    public const string DefaultClaudeModel = "sonnet";
    public const string DefaultGeminiModel = "gemini-3.8-flash";
    private const string FileName = "settings.json";

    public SettingsData Data { get; }
    public MemoryStore Memory { get; } = new();
    public ConversationStore Conversations { get; } = new();
    public ActivityStore Activity { get; } = new();
    public RoutineStore Routines { get; } = new();
    public MeetingStore Meetings { get; } = new();
    public ScreenMemoryStore ScreenMemory { get; } = new();

    /// <summary>Raised after any change, so what depends on a setting can look at it again.</summary>
    public event Action? Changed;

    public AppSettings()
    {
        Data = JarvisFiles.Load<SettingsData>(FileName) ?? new SettingsData();
        Data.VoiceEngine ??= Secrets.GeminiKey is not null ? Jarvis.VoiceEngine.Gemini : Jarvis.VoiceEngine.System;
        Data.GeminiVoice ??= Core.VoiceCatalog.DefaultVoice;
        Data.GeminiVoiceModel ??= Core.VoiceCatalog.DefaultModel;
        Data.KokoroEnglishVoice ??= Core.KokoroCatalog.DefaultEnglishVoice;
        Data.KokoroHindiVoice ??= Core.KokoroCatalog.DefaultHindiVoice;
    }

    public void Update(Action<SettingsData> change)
    {
        change(Data);
        JarvisFiles.Save(Data, FileName);
        Changed?.Invoke();
    }

    /// <summary>Turning on the Hindi assistant also selects the deep Gemini voice, unless they're using Kokoro, which has its own.</summary>
    public void SetHindiAssistant(bool on) => Update(d =>
    {
        d.HindiAssistant = on;
        if (on && d.VoiceEngine != Jarvis.VoiceEngine.Kokoro)
        {
            d.VoiceEngine = Jarvis.VoiceEngine.Gemini;
            d.GeminiVoice = Core.VoiceCatalog.HindiVoice;
        }
    });

    public string? ListeningLanguage => Data.HindiAssistant ? "hi" : null;
    public string? DictationLanguageCode => Data.DictationLanguage == DictationLanguage.Hindi ? "hi" : ListeningLanguage;

    public VoiceConfig VoiceConfig()
    {
        var fallback = Data.VoiceIdentifier;
        if (Data.VoiceEngine == Jarvis.VoiceEngine.Kokoro && KokoroFiles.IsInstalled)
            return new VoiceConfig.Kokoro(Data.KokoroEnglishVoice!.Value, Data.KokoroHindiVoice!.Value, Data.HindiAssistant, fallback, Data.HindiAssistant);
        if (Data.VoiceEngine == Jarvis.VoiceEngine.Gemini && Secrets.GeminiKey is { Length: > 0 } key)
            return new VoiceConfig.Gemini(key, Data.GeminiVoice!, Data.GeminiVoiceModel!,
                Data.HindiAssistant ? Core.VoiceCatalog.HindiStyle : Core.VoiceCatalog.DefaultStyle, Data.HindiAssistant, fallback, Data.HindiAssistant);
        return new VoiceConfig.System(fallback, Data.HindiAssistant);
    }

    public IAIProvider MakeProvider() => Data.Provider switch
    {
        ProviderChoice.Gemini => new GeminiProvider(Secrets.GeminiKey is { Length: > 0 } key ? key : throw new JarvisMessage("Add your Gemini API key in Settings first."), Data.GeminiModel),
        ProviderChoice.Ollama => new OllamaProvider(Data.OllamaModel),
        _ => new ClaudeCodeProvider(Data.ClaudeModel),
    };
}

public sealed class JarvisMessage(string message) : Exception(message);
