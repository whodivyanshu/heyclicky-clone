using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace Jarvis;

/// <summary>Starts the tray app, or runs one of the development commands below.</summary>
public static class Program
{
    private const string InstanceName = "local.jarvis.companion";

    [DllImport("kernel32.dll")] private static extern bool AttachConsole(int process);

    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] != "--demo")
        {
            // Windows apps have no console of their own, so these print to the one that started them.
            AttachConsole(-1);
            var output = new StreamWriter(Console.OpenStandardOutput()) { AutoFlush = true };
            Console.SetOut(output);
            return DevCommands.Run(args);
        }

        // Opening Jarvis again while it's already running brings up Settings, since it has no main window.
        using var single = new Mutex(true, InstanceName, out var isFirst);
        using var reopen = new EventWaitHandle(false, EventResetMode.AutoReset, InstanceName + ".reopen");
        if (!isFirst)
        {
            reopen.Set();
            return 0;
        }

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.DispatcherUnhandledException += (_, e) =>
        {
            // One failed step shouldn't end the app. Only the kind of failure is logged, never its text, which can hold private data.
            Log.Write($"Unhandled: {e.Exception.GetType().Name}");
            e.Handled = true;
        };
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            Log.Write($"Unobserved: {e.Exception.InnerException?.GetType().Name}");
            e.SetObserved();
        };
        Tray? tray = null;
        app.Startup += (_, _) => tray = new Tray(app, args.Contains("--demo"), reopen);
        app.Exit += (_, _) => tray?.Dispose();
        return app.Run();
    }
}

public sealed class Tray : IDisposable
{
    private readonly Application app;
    private readonly AppSettings settings = new();
    private readonly Coordinator coordinator;
    private readonly Forms.NotifyIcon icon;
    private readonly Forms.ToolStripMenuItem meetingItem;
    private readonly Icon idleIcon;
    private readonly IslandController island;
    private SettingsWindow? settingsWindow;
    private bool isRecordingMeeting;

    public Tray(Application app, bool demo, EventWaitHandle reopen)
    {
        this.app = app;
        coordinator = new Coordinator(settings);
        coordinator.OpenSettings = ShowSettings;
        coordinator.OnModeChange = UpdateIcon;
        coordinator.OnMeetingChange = recording =>
        {
            isRecordingMeeting = recording;
            meetingItem!.Text = recording ? "Stop Meeting Notes" : "Start Meeting Notes";
            UpdateIcon(CompanionMode.Idle);
        };

        idleIcon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? SystemIcons.Application;
        meetingItem = new Forms.ToolStripMenuItem("Start Meeting Notes", null, (_, _) => coordinator.ToggleMeeting());
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Settings…", null, (_, _) => ShowSettings());
        menu.Items.Add(meetingItem);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit Jarvis", null, (_, _) => this.app.Shutdown());
        icon = new Forms.NotifyIcon { Icon = idleIcon, Text = "Jarvis", Visible = true, ContextMenuStrip = menu };
        icon.DoubleClick += (_, _) => ShowSettings();

        coordinator.Start();
        island = new IslandController(coordinator.Island, settings);
        island.Start();

        var dispatcher = Dispatcher.CurrentDispatcher;
        var waiter = new Thread(() =>
        {
            while (true)
            {
                reopen.WaitOne();
                dispatcher.BeginInvoke(ShowSettings);
            }
        }) { IsBackground = true };
        waiter.Start();

        if (demo) coordinator.RunDemo();
        else if (!settings.Data.Onboarded || !SpeechModel.IsInstalled)
        {
            settings.Update(d => d.Onboarded = true);
            ShowSettings();
        }
    }

    private void UpdateIcon(CompanionMode mode)
    {
        icon.Text = mode switch
        {
            CompanionMode.Listening => "Jarvis: listening",
            CompanionMode.Thinking => "Jarvis: thinking",
            CompanionMode.Speaking => "Jarvis: speaking",
            _ => isRecordingMeeting ? "Jarvis: taking meeting notes" : "Jarvis",
        };
    }

    private void ShowSettings()
    {
        settingsWindow ??= new SettingsWindow(settings, coordinator);
        settingsWindow.ShowAndFocus();
    }

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
    }
}

/// <summary>The same checks as the Mac app's command line, plus --self-test for CI.</summary>
public static class DevCommands
{
    private static string? Value(string[] args, string flag)
    {
        var index = Array.IndexOf(args, flag);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }

    public static int Run(string[] args)
    {
        try
        {
            if (args[0] == "--self-test") return SelfTest(Value(args, "--self-test"));
            if (args[0] == "--find-app")
            {
                Console.WriteLine(ActionRunner.FindApp(Value(args, "--find-app") ?? "") ?? "no match");
                return 0;
            }
            if (args[0] == "--act") return RunAction(args);
            if (args[0] == "--ask") return Ask(args);
            if (args[0] == "--save-gemini-key")
            {
                // Read from standard input, so it stays out of the shell history and process list.
                var key = (Console.ReadLine() ?? "").Trim();
                var saved = key.Length > 0 && Secrets.SetGeminiKey(key);
                Console.WriteLine(saved ? "Saved the Gemini key." : "Key not saved.");
                return saved ? 0 : 1;
            }
            Console.WriteLine("Unknown command.");
            return 2;
        }
        catch (Exception problem)
        {
            Console.WriteLine($"ERROR: {problem.GetType().Name}: {problem.Message}");
            return 1;
        }
    }

    private static int RunAction(string[] args)
    {
        var parser = Core.ParserNew();
        var beats = Core.ParserFeed(parser, Value(args, "--act") ?? "").Concat(Core.ParserFinish(parser)).ToList();
        if (beats.FirstOrDefault() is not Beat.Act act)
        {
            Console.WriteLine("Not an action tag.");
            return 2;
        }
        var result = ActionRunner.Run(act.Tag, CancellationToken.None).GetAwaiter().GetResult();
        Console.WriteLine(result.Summary + (result.Failure is null ? "" : " | says: " + result.Failure));
        if (result.Data is not null) Console.WriteLine(result.Data);
        return 0;
    }

    /// <summary>One request through the real provider and parser, needing no setup.</summary>
    private static int Ask(string[] args)
    {
        var model = Value(args, "--model");
        IAIProvider provider = Value(args, "--provider") switch
        {
            "gemini" => new GeminiProvider(Environment.GetEnvironmentVariable("GEMINI_API_KEY") ?? Secrets.GeminiKey ?? throw new JarvisMessage("No Gemini key: set GEMINI_API_KEY or save one in Settings."), model ?? AppSettings.DefaultGeminiModel),
            "ollama" => new OllamaProvider(model ?? ""),
            _ => new ClaudeCodeProvider(model ?? AppSettings.DefaultClaudeModel),
        };
        var images = Value(args, "--image") is { } path ? new[] { File.ReadAllBytes(path) } : Array.Empty<byte[]>();
        var system = Core.SystemPrompt(args.Contains("--full-control"), args.Contains("--hindi"), Array.Empty<string>(), false, null);
        var request = new AIRequest(system, Array.Empty<ChatTurn>(), Value(args, "--ask") ?? "Say hello.", images);
        var parser = Core.ParserNew();
        async Task Stream()
        {
            await foreach (var chunk in provider.Stream(request, CancellationToken.None))
                foreach (var beat in Core.ParserFeed(parser, chunk)) Console.WriteLine(beat);
            foreach (var beat in Core.ParserFinish(parser)) Console.WriteLine(beat);
        }
        Stream().GetAwaiter().GetResult();
        return 0;
    }

    /// <summary>
    /// Runs on a real Windows desktop in CI. It exercises what can be checked with nobody there: the bridge loading
    /// with the published files, screen capture, reading the screen, and the windows opening. Results go to a file,
    /// since a windowed app's console output isn't reliable.
    /// </summary>
    private static int SelfTest(string? outputPath)
    {
        var lines = new List<string>();
        var failed = false;
        void Check(string name, Func<string> work)
        {
            try { lines.Add($"ok    {name}: {work()}"); }
            catch (Exception problem)
            {
                failed = true;
                lines.Add($"FAIL  {name}: {problem.GetType().Name}: {problem.Message}");
            }
        }
        void Expect(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException(message);
        }

        Check("bridge refuses dangerous keys", () =>
        {
            foreach (var key in new[] { "alt+f4", "win+r", "shift+delete", "ctrl+q", "esc" }) Expect(Core.ParseKey(key) is null, key);
            return "refused";
        });
        Check("bridge reads keys", () =>
        {
            Expect(Core.ParseKey("ctrl+shift+n") is { Key: "n", Control: true, Shift: true, Alt: false }, "ctrl+shift+n");
            return "read";
        });
        Check("protected apps", () =>
        {
            Expect(Core.RefusesKeyboard("cmd.exe", ""), "cmd");
            Expect(Core.RefusesClick("consent.exe", ""), "consent");
            return "refused";
        });
        Check("prompt", () =>
        {
            var prompt = Core.SystemPrompt(true, false, Array.Empty<string>(), true, null);
            Expect(prompt.Contains("File Explorer"), "Windows wording");
            return $"{prompt.Length} characters";
        });
        Check("displays", () =>
        {
            var displays = ScreenCapture.Displays();
            Expect(displays.Count > 0, "none found");
            return string.Join(", ", displays.Select(d => $"{d.Width}x{d.Height}@{d.Scale:0.##}"));
        });
        Check("screenshot", () =>
        {
            var captured = ScreenCapture.CaptureAll().GetAwaiter().GetResult();
            Expect(captured.Count > 0 && captured[0].Jpeg.Length > 100, "empty");
            return $"{captured.Count} screens, {captured[0].Jpeg.Length} bytes";
        });
        Check("thumbnail", () =>
        {
            var thumbnail = ScreenCapture.Thumbnail().GetAwaiter().GetResult();
            Expect(thumbnail is { Length: > 0 }, "empty");
            return $"{thumbnail!.Length} bytes";
        });
        Check("key context", () => UIInspector.CurrentKeyContext().AppName);
        Check("find controls", () => $"{UIInspector.StartFindingControls().GetAwaiter().GetResult().Count} controls");
        Check("installed apps", () => $"{ActionRunner.InstalledAppNames().Count} apps");
        Check("running apps", () => $"{ActionRunner.RunningAppNames().Count} apps");
        Check("screen memory", () =>
        {
            var folder = Directory.CreateDirectory(JarvisFiles.Folder);
            var store = new ScreenMemoryStore();
            store.Remember("self test zebra phrase", "SelfTest", 1);
            Expect(store.Search("zebra").Count >= 1, "not found");
            store.Clear();
            Expect(store.Count == 0, "not cleared");
            return "stored, found and cleared";
        });
        Check("key storage", () =>
        {
            var before = Secrets.GeminiKey;
            try
            {
                Expect(Secrets.SetGeminiKey("self-test"), "not saved");
                Expect(Secrets.GeminiKey == "self-test", "not read back");
            }
            finally { Secrets.SetGeminiKey(before ?? ""); }
            return "saved and read back";
        });
        Check("windows open", () =>
        {
            var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            var opened = "";
            app.Startup += (_, _) =>
            {
                try
                {
                    var settings = new AppSettings();
                    var coordinator = new Coordinator(settings);
                    coordinator.Start();
                    var island = new IslandController(coordinator.Island, settings);
                    island.Start();
                    new SettingsWindow(settings, coordinator).Show();
                    coordinator.RunDemo();
                    opened = "overlay, island, settings";
                }
                catch (Exception problem)
                {
                    opened = $"failed: {problem.GetType().Name}: {problem.Message}";
                }
                var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
                timer.Tick += (_, _) => app.Shutdown();
                timer.Start();
            };
            app.DispatcherUnhandledException += (_, e) =>
            {
                opened = $"failed: {e.Exception.GetType().Name}: {e.Exception.Message}";
                e.Handled = true;
            };
            app.Run();
            Expect(!opened.StartsWith("failed", StringComparison.Ordinal) && opened.Length > 0, opened);
            return opened;
        });

        var report = string.Join(Environment.NewLine, lines) + Environment.NewLine + (failed ? "FAILED" : "PASSED") + Environment.NewLine;
        if (outputPath is not null) File.WriteAllText(outputPath, report);
        Console.Write(report);
        return failed ? 1 : 0;
    }
}
