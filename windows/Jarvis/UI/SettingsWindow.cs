using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;

namespace Jarvis;

/// <summary>The Settings window, with the same pages as the Mac app, apart from what's Apple's alone.</summary>
public sealed class SettingsWindow : Window
{
    private enum Tab { General, Voice, AI, HandsFree, Routines, Meetings, Teaching, ScreenMemory, Memory, History, Activity, Safety, Setup }

    private static readonly (Tab Tab, string Title, string Icon)[] Tabs =
    {
        (Tab.General, "General", ""), (Tab.Voice, "Voice", ""), (Tab.AI, "AI", ""), (Tab.HandsFree, "Hands-free", ""),
        (Tab.Routines, "Routines", ""), (Tab.Meetings, "Meetings", ""), (Tab.Teaching, "Teaching", ""), (Tab.ScreenMemory, "Screen memory", ""),
        (Tab.Memory, "Memory", ""), (Tab.History, "History", ""), (Tab.Activity, "Activity", ""), (Tab.Safety, "Safety", ""), (Tab.Setup, "Setup", ""),
    };

    private static readonly SolidColorBrush Sidebar = Solid(14, 14, 14), CardBrush = Solid(23, 23, 23), LineBrush = White(23), Secondary = White(140), SelectedBrush = White(28);

    private static SolidColorBrush Solid(byte r, byte g, byte b) => new(Color.FromRgb(r, g, b));
    private static SolidColorBrush White(byte alpha) => new(Color.FromArgb(alpha, 255, 255, 255));

    private readonly AppSettings settings;
    private readonly Coordinator coordinator;
    private readonly StackPanel sidebarList = new();
    private readonly ContentControl page = new();
    private readonly TextBlock pageTitle = new() { FontSize = 24, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, Margin = new Thickness(0, 0, 0, 18) };
    private readonly TextBlock readyLabel = new() { FontSize = 12, Foreground = Secondary };
    private readonly SpeechOutput preview = new();
    private Tab tab;

    // State kept between redraws of a page.
    private string testResult = "", previewResult = "", keyDraft = "", historyQuery = "", memoryQuery = "", routineName = "", routineWhen = "", routineRequest = "", routineProblem = "";
    private bool isTesting;
    private List<ScreenMemoryHit> memoryResults = new();
    private bool memorySearched;
    private Guid? openedMeeting;
    private readonly HashSet<Guid> remindersAdded = new();
    private List<string>? ollamaModels;
    private bool ollamaChecked;

    public SettingsWindow(AppSettings settings, Coordinator coordinator)
    {
        this.settings = settings;
        this.coordinator = coordinator;
        tab = NeedsSetup ? Tab.Setup : Tab.General;
        Title = "Jarvis";
        Width = 800;
        Height = 660;
        ResizeMode = ResizeMode.CanMinimize;
        Background = Brushes.Black;
        Foreground = Brushes.White;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
        Icon = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri("pack://application:,,,/Assets/Jarvis.ico"));

        var layout = new DockPanel();
        var side = new DockPanel { Width = 196, Background = Sidebar };
        var brand = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(18, 22, 8, 14) };
        brand.Children.Add(JarvisStyle.SparkMark(26));
        brand.Children.Add(new TextBlock { Text = "Jarvis", FontSize = 16, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
        DockPanel.SetDock(brand, Dock.Top);
        side.Children.Add(brand);
        readyLabel.Margin = new Thickness(20, 0, 0, 16);
        DockPanel.SetDock(readyLabel, Dock.Bottom);
        side.Children.Add(readyLabel);
        sidebarList.Margin = new Thickness(10, 0, 10, 0);
        side.Children.Add(sidebarList);
        DockPanel.SetDock(side, Dock.Left);
        layout.Children.Add(side);
        var content = new StackPanel { Margin = new Thickness(32, 28, 32, 28) };
        content.Children.Add(pageTitle);
        content.Children.Add(page);
        layout.Children.Add(new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Content = layout;

        SpeechModel.Changed += QueueRedraw;
        KokoroInstaller.Shared.Changed += QueueRedraw;
        Redraw();
    }

    private static bool NeedsSetup => !SpeechModel.IsInstalled || !MicrophoneAllowed;

    /// <summary>Desktop apps have one switch in Windows, and this reads it. Anything unreadable counts as allowed, and opening the microphone will report the real problem.</summary>
    private static bool MicrophoneAllowed
    {
        get
        {
            foreach (var root in new[] { Registry.LocalMachine, Registry.CurrentUser })
            {
                using var key = root.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone");
                if (key?.GetValue("Value") as string == "Deny") return false;
            }
            return true;
        }
    }

    private void QueueRedraw() => Dispatcher.BeginInvoke(Redraw);

    public void ShowAndFocus()
    {
        Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        // Jarvis keeps running in the tray, so this only hides.
        e.Cancel = true;
        preview.Stop();
        Hide();
    }

    private void Redraw()
    {
        sidebarList.Children.Clear();
        foreach (var (item, title, icon) in Tabs)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(new TextBlock { Text = icon, FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 13, Width = 22, VerticalAlignment = VerticalAlignment.Center, Foreground = item == tab ? Brushes.White : Secondary });
            row.Children.Add(new TextBlock { Text = title, FontSize = 13, FontWeight = FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center, Foreground = item == tab ? Brushes.White : Secondary });
            var border = new Border { Background = item == tab ? SelectedBrush : Brushes.Transparent, CornerRadius = new CornerRadius(9), Padding = new Thickness(10, 0, 10, 0), Height = 31, Child = row };
            var selected = item;
            sidebarList.Children.Add(JarvisStyle.Plain(border, () =>
            {
                tab = selected;
                Redraw();
            }));
        }
        readyLabel.Text = NeedsSetup ? "○  Setup needed" : "●  Ready";
        pageTitle.Text = Tabs.First(t => t.Tab == tab).Title;
        page.Content = tab switch
        {
            Tab.General => GeneralPage(),
            Tab.Voice => VoicePage(),
            Tab.AI => AiPage(),
            Tab.HandsFree => HandsFreePage(),
            Tab.Routines => RoutinesPage(),
            Tab.Meetings => MeetingsPage(),
            Tab.Teaching => TeachingPage(),
            Tab.ScreenMemory => ScreenMemoryPage(),
            Tab.Memory => MemoryPage(),
            Tab.History => HistoryPage(),
            Tab.Activity => ActivityPage(),
            Tab.Safety => SafetyPage(),
            _ => SetupPage(),
        };
    }

    // MARK: Parts

    private static StackPanel Stack(params UIElement[] children)
    {
        var stack = new StackPanel();
        foreach (var child in children)
        {
            if (child is FrameworkElement element && element.Margin == default) element.Margin = new Thickness(0, 0, 0, 18);
            stack.Children.Add(child);
        }
        return stack;
    }

    private static Border Card(params UIElement[] rows)
    {
        var list = new StackPanel();
        for (var i = 0; i < rows.Length; i++)
        {
            if (i > 0) list.Children.Add(new Border { Height = 1, Background = LineBrush });
            list.Children.Add(rows[i]);
        }
        return new Border { Background = CardBrush, BorderBrush = LineBrush, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(13), Child = list };
    }

    private static UIElement Row(string title, string? detail = null, UIElement? control = null)
    {
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = title, FontSize = 13, FontWeight = FontWeights.Medium, Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap });
        if (!string.IsNullOrEmpty(detail)) text.Children.Add(new TextBlock { Text = detail, FontSize = 11, Foreground = Secondary, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 0) });
        var row = new DockPanel { MinHeight = 50, Margin = new Thickness(15, 3, 15, 3) };
        if (control is not null)
        {
            DockPanel.SetDock(control, Dock.Right);
            if (control is FrameworkElement element)
            {
                element.VerticalAlignment = VerticalAlignment.Center;
                element.Margin = new Thickness(16, 0, 0, 0);
            }
            row.Children.Add(control);
        }
        row.Children.Add(text);
        return row;
    }

    private static TextBlock Note(string text) => new() { Text = text, FontSize = 12, Foreground = Secondary, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(4, 0, 4, 18) };

    private Button Toggle(bool isOn, Action<bool> changed)
    {
        var knob = new Border { Width = 18, Height = 18, CornerRadius = new CornerRadius(9), Background = isOn ? Brushes.Black : White(191), HorizontalAlignment = isOn ? HorizontalAlignment.Right : HorizontalAlignment.Left, Margin = new Thickness(2) };
        var track = new Border { Width = 38, Height = 22, CornerRadius = new CornerRadius(11), Background = isOn ? Brushes.White : White(36), Child = knob };
        var button = JarvisStyle.Plain(track, () =>
        {
            changed(!isOn);
            Redraw();
        });
        System.Windows.Automation.AutomationProperties.SetName(button, isOn ? "On" : "Off");
        return button;
    }

    private Button Outline(string title, Action action, bool enabled = true)
    {
        var label = new TextBlock { Text = title, FontSize = 12, FontWeight = FontWeights.Medium, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center };
        var border = new Border { Height = 28, Padding = new Thickness(12, 0, 12, 0), CornerRadius = new CornerRadius(14), Background = White(20), BorderBrush = White(36), BorderThickness = new Thickness(1), Child = label };
        var button = JarvisStyle.Plain(border, action);
        button.IsEnabled = enabled;
        button.Opacity = enabled ? 1 : 0.4;
        return button;
    }

    private static TextBox Field(string text, double width, Action<string> changed, string hint = "")
    {
        var box = new TextBox
        {
            Text = text, Width = width, Height = 28, FontSize = 12, Background = White(18), Foreground = Brushes.White, BorderBrush = LineBrush, CaretBrush = Brushes.White,
            VerticalContentAlignment = VerticalAlignment.Center, Padding = new Thickness(6, 0, 6, 0), ToolTip = hint.Length > 0 ? hint : null,
        };
        box.TextChanged += (_, _) => changed(box.Text);
        return box;
    }

    private static ComboBox Picker<T>(IEnumerable<(T Value, string Title)> options, T selected, Action<T> changed)
    {
        var box = new ComboBox { MinWidth = 170, FontSize = 12 };
        foreach (var (value, title) in options)
        {
            var item = new ComboBoxItem { Content = title, Tag = value };
            box.Items.Add(item);
            if (EqualityComparer<T>.Default.Equals(value, selected)) box.SelectedItem = item;
        }
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedItem is ComboBoxItem { Tag: T value }) changed(value);
        };
        return box;
    }

    private UIElement Segmented<T>((T Value, string Title)[] options, T selected, Action<T> changed)
    {
        var row = new UniformGrid { Rows = 1, Margin = new Thickness(0, 0, 0, 18) };
        foreach (var (value, title) in options)
        {
            var isOn = EqualityComparer<T>.Default.Equals(value, selected);
            var border = new Border
            {
                Height = 30, CornerRadius = new CornerRadius(8), Margin = new Thickness(0, 0, 4, 0), Background = isOn ? SelectedBrush : White(10),
                Child = new TextBlock { Text = title, FontSize = 12, FontWeight = FontWeights.Medium, Foreground = isOn ? Brushes.White : Secondary, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
            };
            var chosen = value;
            row.Children.Add(JarvisStyle.Plain(border, () =>
            {
                changed(chosen);
                Redraw();
            }));
        }
        return row;
    }

    private void Do(Action<SettingsData> change) => settings.Update(change);

    private static void OpenFolderOrFile(string path)
    {
        try { using var _ = Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true }); }
        catch (Exception problem) when (problem is System.ComponentModel.Win32Exception or InvalidOperationException) { Log.Write("Opening a path failed."); }
    }

    // MARK: Pages

    private UIElement HowToStep(string icon, string title, string detail)
    {
        var stack = new StackPanel();
        stack.Children.Add(new TextBlock { Text = icon, FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 16, Foreground = Brushes.White });
        stack.Children.Add(new TextBlock { Text = title, FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, Margin = new Thickness(0, 8, 0, 0), TextWrapping = TextWrapping.Wrap });
        stack.Children.Add(new TextBlock { Text = detail, FontSize = 11, Foreground = Secondary, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) });
        return new Border { Background = CardBrush, BorderBrush = LineBrush, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(13), Padding = new Thickness(13), Height = 100, Margin = new Thickness(0, 0, 8, 0), Child = stack };
    }

    private UIElement GeneralPage()
    {
        var d = settings.Data;
        var steps = new UniformGrid { Rows = 1, Margin = new Thickness(0, 0, -8, 18) };
        steps.Children.Add(HowToStep("", $"Hold {d.Hotkey.Title()}", "Ask about anything on screen"));
        steps.Children.Add(HowToStep("", "Let go", "Jarvis answers and points"));
        steps.Children.Add(HowToStep("", "Press Esc", "Stops it at any time"));
        return Stack(
            steps,
            Card(
                Row("Hold to talk", null, Picker(Enum.GetValues<HotkeyChoice>().Select(k => (k, k.Title())), d.Hotkey, k => Do(s => s.Hotkey = k))),
                Row("Open Jarvis when you sign in", null, Toggle(AutoStart.IsOn, AutoStart.Set)),
                Row("Show the island when idle", "Hover over it to chat or type a question", Toggle(d.ShowIslandWhenIdle, v => Do(s => s.ShowIslandWhenIdle = v))),
                Row("Show the pointer when idle", "The small pointer that follows your cursor", Toggle(d.ShowWhenIdle, v => Do(s => s.ShowWhenIdle = v))),
                Row("Let Jarvis control my PC", "Finishes whole jobs by itself, and asks you before anything like sending, deleting or paying. Press Esc to stop it", Toggle(d.ControlsPC, v => Do(s => s.ControlsPC = v)))),
            Note("Say \"teach me...\" or \"walk me through...\" and Jarvis guides you click by click. It circles each step and moves on when you click it. Without full control, \"how do I...\" does this too."));
    }

    private UIElement VoicePage()
    {
        var d = settings.Data;
        var rows = new List<UIElement>
        {
            Row("Hindi assistant", "Listens and replies in Hindi, with a deep, calm voice", Toggle(d.HindiAssistant, settings.SetHindiAssistant)),
        };
        string note;
        switch (d.VoiceEngine)
        {
            case VoiceEngine.Gemini:
                rows.Add(Row("Voice", null, Picker(Core.VoiceCatalog.Voices.Select(v => (v.Name, $"{v.Name} ({v.Style})")), d.GeminiVoice!, v => Do(s => s.GeminiVoice = v))));
                rows.Add(Row("Voice model", null, Field(d.GeminiVoiceModel!, 230, v => Do(s => s.GeminiVoiceModel = v))));
                note = "Sounds natural, but takes a few extra seconds to start, has a daily limit and is billed to your Gemini key. If a request fails, Jarvis uses the Windows voice for that reply.";
                break;
            case VoiceEngine.Kokoro:
                rows.AddRange(KokoroRows());
                note = "Free, with no limit from any service, and runs on this PC once downloaded. Install it, then play a sample in each language to judge it. The first sentence takes longer while the model loads. Until it's installed, Jarvis uses the Windows voice.";
                break;
            default:
                var voices = WindowsVoice.BestVoices().Select(v => (v.Id, v.Name)).Prepend(("", "Best available"));
                rows.Add(Row("Voice", d.HindiAssistant && !WindowsVoice.HasHindi ? "Add a Hindi voice in Windows Settings, under Time & language, Speech, to hear Hindi" : null,
                    Picker(voices, d.VoiceIdentifier, v => Do(s => s.VoiceIdentifier = v))));
                note = "Free, works offline and starts right away. More voices are in Windows Settings, under Time & language, Speech.";
                break;
        }
        rows.Add(Row("Preview", previewResult.Length == 0 ? null : previewResult, Outline("Play sample", PreviewVoice)));
        return Stack(
            Segmented(new[] { (VoiceEngine.Gemini, "Gemini voice"), (VoiceEngine.System, "Windows voice"), (VoiceEngine.Kokoro, "Kokoro") }, d.VoiceEngine!.Value, v => Do(s => s.VoiceEngine = v)),
            Card(rows.ToArray()),
            Note(note));
    }

    private IEnumerable<UIElement> KokoroRows()
    {
        var d = settings.Data;
        var catalog = Core.KokoroCatalog;
        var installer = KokoroInstaller.Shared;
        if (KokoroFiles.IsInstalled)
        {
            yield return Row("English voice", null, Picker(catalog.EnglishVoices.Select(v => (v.Id, $"{v.Name} ({v.Description})")), d.KokoroEnglishVoice!.Value, v => Do(s => s.KokoroEnglishVoice = v)));
            yield return Row("Hindi voice", "Used for any reply written in Hindi", Picker(catalog.HindiVoices.Select(v => (v.Id, $"{v.Name} ({v.Description})")), d.KokoroHindiVoice!.Value, v => Do(s => s.KokoroHindiVoice = v)));
            yield return Row("Installed on this PC", "Takes about 220 MB", Outline("Remove", installer.Remove));
        }
        else if (installer.IsWorking) yield return Row("Installing Kokoro", installer.Status);
        else
        {
            var total = catalog.Runtime.Megabytes + catalog.Model.Megabytes;
            yield return Row("Install Kokoro",
                installer.Problem.Length > 0 ? installer.Problem : $"Downloads about {total} MB from the sherpa-onnx project on GitHub, and checks each file before installing it",
                Outline(installer.Problem.Length > 0 ? "Try again" : "Download", installer.Install));
        }
    }

    private void PreviewVoice()
    {
        var d = settings.Data;
        previewResult = d.VoiceEngine == VoiceEngine.Gemini && Secrets.GeminiKey is null ? "No Gemini key saved, so this is the Windows voice."
            : d.VoiceEngine == VoiceEngine.Kokoro && !KokoroFiles.IsInstalled ? "Kokoro isn't installed yet, so this is the Windows voice."
            : "";
        preview.GetVoiceConfig = settings.VoiceConfig;
        preview.OnVoiceError = message =>
        {
            previewResult = message;
            Redraw();
        };
        preview.Begin();
        preview.Enqueue(new Beat[] { new Beat.Say(d.HindiAssistant
            ? "नमस्ते, मैं जार्विस हूँ। शॉर्टकट दबाकर रखिए और अपनी स्क्रीन के बारे में कुछ भी पूछिए।"
            : "Hi, I'm Jarvis. Hold the shortcut and ask me about anything on your screen.") });
        preview.FinishInput();
        Redraw();
    }

    private UIElement AiPage()
    {
        var d = settings.Data;
        var rows = new List<UIElement>();
        switch (d.Provider)
        {
            case ProviderChoice.ClaudeCode:
                rows.Add(Row("Model", null, Picker(new[] { ("sonnet", "Sonnet: balanced"), ("haiku", "Haiku: fastest"), ("opus", "Opus: most capable") }, d.ClaudeModel, v => Do(s => s.ClaudeModel = v))));
                break;
            case ProviderChoice.Gemini:
                rows.Add(Row("Model", null, Field(d.GeminiModel, 230, v => Do(s => s.GeminiModel = v))));
                break;
            default:
                if (!ollamaChecked) CheckOllama();
                if (ollamaModels is { Count: > 0 } models)
                    rows.Add(Row("Model", "Pick a model that can read images, or Jarvis won't be able to see your screen",
                        Picker(models.Select(m => (m, m)).Prepend(("", "Choose a model")), d.OllamaModel, v => Do(s => s.OllamaModel = v))));
                else
                    rows.Add(Row("Model", !ollamaChecked ? "Checking…" : ollamaModels is null ? "Ollama isn't running. Start it, then check again." : "No models installed yet. Run: ollama pull llama3.2-vision", Outline("Check again", CheckOllama)));
                break;
        }
        if (d.Provider == ProviderChoice.Gemini || d.VoiceEngine == VoiceEngine.Gemini)
        {
            var hasKey = Secrets.GeminiKey is not null;
            var keyBox = new PasswordBox { Width = 170, Height = 28, FontSize = 12, Background = White(18), Foreground = Brushes.White, BorderBrush = LineBrush, CaretBrush = Brushes.White, VerticalContentAlignment = VerticalAlignment.Center, ToolTip = hasKey ? "Replace key" : "Paste key" };
            keyBox.PasswordChanged += (_, _) => keyDraft = keyBox.Password;
            var controls = new StackPanel { Orientation = Orientation.Horizontal };
            controls.Children.Add(keyBox);
            var save = Outline("Save", SaveKey);
            save.Margin = new Thickness(8, 0, 0, 0);
            controls.Children.Add(save);
            rows.Add(Row("Gemini API key", hasKey ? "Saved, encrypted for your Windows account" : "Not saved yet", controls));
        }
        rows.Add(Row("Connection", testResult.Length == 0 ? null : testResult, Outline(isTesting ? "Testing…" : "Test", TestConnection, !isTesting)));

        return Stack(
            Segmented(new[] { (ProviderChoice.ClaudeCode, "Claude Code"), (ProviderChoice.Gemini, "Gemini"), (ProviderChoice.Ollama, "Ollama") }, d.Provider, v => Do(s => s.Provider = v)),
            Card(rows.ToArray()),
            Note(d.Provider switch
            {
                ProviderChoice.Ollama => "Runs on this PC, so your screenshots and questions stay here. Pointing and clicking need a model that can read images, and are usually less accurate than the online models.",
                ProviderChoice.ClaudeCode => "Uses the claude command and your existing login. Requests count toward your Claude plan.",
                _ => "Uses your API key, which is stored on this PC and encrypted for your Windows account.",
            }));
    }

    private async void CheckOllama()
    {
        ollamaModels = await OllamaProvider.InstalledModels();
        ollamaChecked = true;
        Redraw();
    }

    private void SaveKey()
    {
        var key = keyDraft.Trim();
        if (key.Length == 0) return;
        testResult = Secrets.SetGeminiKey(key) ? "Key saved." : "Couldn't save the key.";
        keyDraft = "";
        Redraw();
    }

    private async void TestConnection()
    {
        isTesting = true;
        testResult = "";
        Redraw();
        try
        {
            var reply = "";
            using var wait = new CancellationTokenSource(TimeSpan.FromSeconds(60));
            await foreach (var chunk in settings.MakeProvider().Stream(new AIRequest("Reply with one short friendly sentence.", "Say that the connection works."), wait.Token)) reply += chunk;
            testResult = reply.Length == 0 ? "No reply came back." : reply;
        }
        catch (JarvisMessage problem) { testResult = problem.Message; }
        catch (OperationCanceledException) { testResult = "No reply came back in time."; }
        catch (Exception problem)
        {
            Log.Write($"The connection test failed: {problem.GetType().Name}");
            testResult = "That didn't work. Check your connection and try again.";
        }
        isTesting = false;
        Redraw();
    }

    private UIElement HandsFreePage()
    {
        var d = settings.Data;
        return Stack(
            Card(
                Row("Dictate anywhere", "Hold this, speak, and let go. Your words appear wherever you're typing", Picker(Enum.GetValues<DictationHotkey>().Select(k => (k, k.Title())), d.DictationHotkey, v => Do(s => s.DictationHotkey = v))),
                Row("Dictation language", "Hindi also works for Hindi mixed with English", Picker(new[] { (DictationLanguage.System, "Detect by itself"), (DictationLanguage.Hindi, "Hindi, and Hindi with English") }, d.DictationLanguage, v => Do(s => s.DictationLanguage = v))),
                Row("Clean up dictation with AI", "Fixes punctuation and false starts, but sends what you said to your AI and is a little slower. Removing \"um\" and \"uh\" is always free", Toggle(d.DictationCleanup, v => Do(s => s.DictationCleanup = v)))),
            Card(
                Row("Talk over Jarvis to interrupt", "Speak while Jarvis is talking and it stops and listens. Say \"stop\" to just stop it. Works best with headphones", Toggle(d.BargeInEnabled, v => Do(s => s.BargeInEnabled = v))),
                Row("Listen for \"Hey Jarvis\"", "Say it, then your request. The microphone stays on while Jarvis is idle, and Windows shows its microphone icon", Toggle(d.WakeWordEnabled, v => Do(s => s.WakeWordEnabled = v))),
                Row("Keep listening after a reply", "Listens for 6 seconds after a spoken reply, so you can carry on without the shortcut", Toggle(d.FollowUpEnabled, v => Do(s => s.FollowUpEnabled = v))),
                Row("Offer help with problems on screen", "Looks for messages like \"Build failed\" and offers to help, at most once every 5 minutes", Toggle(d.ScreenWatchEnabled, v => Do(s => s.ScreenWatchEnabled = v)))),
            Note("\"Hey Jarvis\" is recognized on this PC, and no audio leaves it until a request is sent to your AI. Listening all the time uses more battery and processor. Offers read your screen on this PC every 20 seconds, and nothing is sent to your AI unless you choose \"Take a look\"."));
    }

    private UIElement RoutinesPage()
    {
        var items = new List<UIElement>();
        var routines = Core.RoutineList(settings.Routines.Book);
        if (routines.Count > 0)
        {
            items.Add(Card(routines.Select(r => Row(r.Name, $"{r.When}: {r.Request}", Outline("Delete", () =>
            {
                settings.Routines.Set(Core.RoutineRemoveId(settings.Routines.Book, r.Id));
                Redraw();
            }))).ToArray()));
        }
        items.Add(Card(
            Row("Name", null, Field(routineName, 300, v => routineName = v, "Focus")),
            Row("When", null, Field(routineWhen, 300, v => routineWhen = v, "say focus mode, or weekdays 09:00")),
            Row("What to do", null, Field(routineRequest, 300, v => routineRequest = v, "Quit Slack and open Notepad")),
            Row("Add routine", routineProblem.Length == 0 ? null : routineProblem, Outline("Add", AddRoutine))));
        items.Add(Note("You can also say \"every morning at 9, open my work apps and read my calendar\". A routine you start by saying its phrase works like any request. A scheduled one never sees your screen, clicks or types, in case you're away. It runs within 5 minutes of its time if the PC is awake and unlocked, and is skipped otherwise."));
        return Stack(items.ToArray());
    }

    private void AddRoutine()
    {
        if (routineName.Trim().Length == 0 || routineWhen.Trim().Length == 0 || routineRequest.Trim().Length == 0) return;
        var (problem, book) = Core.RoutineAddParts(settings.Routines.Book, routineName.Trim(), routineWhen.Trim(), routineRequest.Trim());
        if (problem == "when") routineProblem = "Try \"say focus mode\", \"daily 09:00\", \"weekdays 18:30\" or \"mon,thu 08:00\".";
        else if (problem == "full") routineProblem = "You've reached the limit of 30 routines.";
        else
        {
            settings.Routines.Set(book!);
            routineName = routineWhen = routineRequest = routineProblem = "";
        }
        Redraw();
    }

    private UIElement MeetingsPage()
    {
        var notes = settings.Meetings.Notes;
        UIElement list = notes.Count == 0
            ? Card(Row("No meeting notes yet", "Say \"start meeting notes\" or use the tray icon"))
            : Card(Enumerable.Reverse(notes).Select(MeetingRow).ToArray());
        return Stack(list, Note("A red dot on the island shows when Jarvis is taking notes. It hears your microphone and your PC's sound, and turns them into text on this PC without keeping any audio. Tell people on the call before you start, because some places require their consent. The transcript goes to your chosen AI for the summary, and notes stop by themselves after 3 hours."));
    }

    private UIElement MeetingRow(MeetingNote note)
    {
        var panel = new StackPanel { Margin = new Thickness(15, 10, 15, 10) };
        var top = new DockPanel { LastChildFill = false };
        top.Children.Add(new TextBlock { Text = note.Start.ToString("g", CultureInfo.CurrentCulture), FontSize = 13, FontWeight = FontWeights.Medium, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        void Add(Button button)
        {
            button.Margin = new Thickness(8, 0, 0, 0);
            buttons.Children.Add(button);
        }
        Add(Outline(openedMeeting == note.Id ? "Hide" : "Open", () =>
        {
            openedMeeting = openedMeeting == note.Id ? null : note.Id;
            Redraw();
        }));
        Add(Outline("Copy", () => Clipboard.SetText(string.Join("\n\n", new[] { note.Summary, note.Transcript }.Where(t => !string.IsNullOrEmpty(t))))));
        Add(Outline("Delete", () =>
        {
            settings.Meetings.Remove(note.Id);
            Redraw();
        }));
        DockPanel.SetDock(buttons, Dock.Right);
        top.Children.Add(buttons);
        panel.Children.Add(top);
        if (note.Problem is { } problem)
        {
            panel.Children.Add(new TextBlock { Text = problem, FontSize = 11, Foreground = JarvisStyle.AmberBrush, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 8) });
            panel.Children.Add(new Border
            {
                HorizontalAlignment = HorizontalAlignment.Left,
                Child = Outline("Try again", async () =>
                {
                    await coordinator.Summarize(note);
                    Redraw();
                }),
            });
        }
        if (openedMeeting == note.Id)
        {
            if (note.Summary is { } summary)
            {
                panel.Children.Add(Selectable(summary, 12, Brushes.White));
                var items = Core.MeetingActionItems(summary);
                if (items.Count > 0)
                {
                    var added = remindersAdded.Contains(note.Id);
                    panel.Children.Add(new Border
                    {
                        HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0),
                        Child = Outline(added ? "Added to tasks" : $"Add {items.Count} action items to tasks", () => AddTasks(items, note), !added),
                    });
                }
            }
            panel.Children.Add(Selectable(note.Transcript, 11, Secondary));
        }
        return panel;
    }

    private async void AddTasks(List<string> items, MeetingNote note)
    {
        foreach (var item in items)
        {
            // A bar would be read as the due date.
            var result = await NativeServices.AddReminder(item.Replace("|", " "));
            if (result.Failure is { } failure)
            {
                note.Problem = failure;
                Redraw();
                return;
            }
        }
        remindersAdded.Add(note.Id);
        Redraw();
    }

    private static TextBox Selectable(string text, double size, Brush brush) => new()
    {
        Text = text, FontSize = size, Foreground = brush, Background = Brushes.Transparent, BorderThickness = new Thickness(0), IsReadOnly = true, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0), CaretBrush = Brushes.Transparent,
    };

    private UIElement TeachingPage()
    {
        var packs = TeachingFiles.Custom().Concat(Core.BuiltInPacks()).Select(p => Row(p.Name, (p.IsBuiltIn ? "Built in, for " : "Yours, for ") + string.Join(", ", p.Apps))).ToArray();
        var open = Outline("Open my teaching packs folder", () =>
        {
            Directory.CreateDirectory(JarvisFiles.TeachingPacks);
            OpenFolderOrFile(JarvisFiles.TeachingPacks);
        });
        open.HorizontalAlignment = HorizontalAlignment.Left;
        open.Margin = new Thickness(0, 0, 0, 18);
        return Stack(
            Card(Row("Use teaching notes", "When you ask to learn something, Jarvis adds notes for the app in front of you", Toggle(settings.Data.TeachingEnabled, v => Do(s => s.TeachingEnabled = v)))),
            Card(packs),
            open,
            Note("Add your own by saving a .md file in that folder. Its first line names the apps, such as \"apps: Figma, FigJam\", and the rest is your notes in plain words. Yours come before a built-in pack for the same app."));
    }

    private UIElement ScreenMemoryPage()
    {
        var d = settings.Data;
        var count = settings.ScreenMemory.Count;
        var search = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 18) };
        search.Children.Add(Field(memoryQuery, 300, v => memoryQuery = v, "Search what was on your screen"));
        var go = Outline("Search", () =>
        {
            memoryResults = settings.ScreenMemory.Search(memoryQuery);
            memorySearched = true;
            Redraw();
        });
        go.Margin = new Thickness(8, 0, 0, 0);
        search.Children.Add(go);

        var items = new List<UIElement>
        {
            Card(
                Row("Remember text from my screen", "Reads your screen every 20 seconds, so you can ask \"where did I see that error yesterday?\"", Toggle(d.ScreenMemoryEnabled, v => Do(s => s.ScreenMemoryEnabled = v))),
                Row("Keep it for", null, Picker(new[] { (1, "1 day"), (7, "7 days"), (30, "30 days") }, d.ScreenMemoryDays, v => Do(s => s.ScreenMemoryDays = v))),
                Row("Saved", $"{count} screens", Outline("Delete everything", () =>
                {
                    settings.ScreenMemory.Clear();
                    memoryResults = new();
                    Redraw();
                }, count > 0))),
            search,
        };
        if (memoryResults.Count > 0) items.Add(Card(memoryResults.Select(hit => Row(hit.Snippet, $"{hit.App}, {hit.Date.ToString("g", CultureInfo.CurrentCulture)}")).ToArray()));
        else if (memorySearched) items.Add(Note("Nothing matches that."));
        items.Add(Note("Only text is kept, never images, on this PC in a file only your account can read. It can still hold private things you had on screen. Jarvis skips password fields, password managers, private browser windows, a locked screen and apps you've blocked, and hides what looks like card numbers, keys and passwords, but it can miss some. When you ask about something you saw, the matching text goes to your chosen AI."));
        return Stack(items.ToArray());
    }

    private UIElement MemoryPage()
    {
        var facts = settings.Memory.Facts;
        var items = new List<UIElement>();
        if (facts.Count == 0) items.Add(Card(Row("Nothing saved yet", "Say something like \"remember that my main project is Jarvis\"")));
        else
        {
            items.Add(Card(facts.Select(fact => Row(fact, null, Outline("Delete", () =>
            {
                settings.Memory.Remove(fact);
                Redraw();
            }))).ToArray()));
            var clear = Outline("Forget everything", () =>
            {
                settings.Memory.Clear();
                Redraw();
            });
            clear.HorizontalAlignment = HorizontalAlignment.Left;
            clear.Margin = new Thickness(0, 0, 0, 18);
            items.Add(clear);
        }
        items.Add(Note("Saved only on this PC, and sent to your chosen AI with each request. Jarvis saves a fact when you ask it to remember something or state a lasting preference."));
        return Stack(items.ToArray());
    }

    private UIElement HistoryPage()
    {
        var conversations = settings.Conversations;
        var bar = new DockPanel { LastChildFill = false, Margin = new Thickness(0, 0, 0, 18) };
        var box = Field(historyQuery, 300, v => historyQuery = v, "Search your conversations");
        bar.Children.Add(box);
        var go = Outline("Search", Redraw);
        go.Margin = new Thickness(8, 0, 0, 0);
        bar.Children.Add(go);
        if (conversations.Entries.Count > 0)
        {
            var clear = Outline("Delete all", () =>
            {
                conversations.Clear();
                Redraw();
            });
            DockPanel.SetDock(clear, Dock.Right);
            bar.Children.Add(clear);
        }
        var results = conversations.Search(historyQuery).Take(100).ToList();
        var items = new List<UIElement>
        {
            Card(Row("Save my conversations", "What you said and what Jarvis replied. Screenshots and selected text aren't saved", Toggle(settings.Data.SaveConversations, v => Do(s => s.SaveConversations = v)))),
            bar,
        };
        if (results.Count == 0) items.Add(Note(conversations.Entries.Count == 0 ? "Nothing saved yet." : "Nothing matches that."));
        else
        {
            items.Add(Card(results.Select(entry =>
            {
                var text = new StackPanel();
                text.Children.Add(new TextBlock { Text = entry.User, FontSize = 13, FontWeight = FontWeights.Medium, Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap });
                text.Children.Add(Selectable(entry.Assistant, 12, Secondary));
                text.Children.Add(new TextBlock { Text = entry.Date.ToString("g", CultureInfo.CurrentCulture), FontSize = 11, Foreground = Secondary });
                var row = new DockPanel { Margin = new Thickness(15, 10, 15, 10) };
                var delete = Outline("Delete", () =>
                {
                    conversations.Remove(entry.Id);
                    Redraw();
                });
                delete.Margin = new Thickness(12, 0, 0, 0);
                delete.VerticalAlignment = VerticalAlignment.Top;
                DockPanel.SetDock(delete, Dock.Right);
                row.Children.Add(delete);
                row.Children.Add(text);
                return (UIElement)row;
            }).ToArray()));
        }
        items.Add(Note($"Saved only on this PC, in a file only your account can read, and limited to the latest {ConversationStore.MaxEntries}. Past conversations aren't sent to your AI after you quit."));
        return Stack(items.ToArray());
    }

    private UIElement ActivityPage()
    {
        var activity = settings.Activity;
        var d = settings.Data;
        var items = new List<UIElement>
        {
            Card(
                Row("Keep a record of what Jarvis does", "Every click, key, app and action, and whether it worked. It can include what Jarvis typed", Toggle(d.KeepActivityLog, v => Do(s => s.KeepActivityLog = v))),
                Row("Keep a screenshot for each step", "Shows what Jarvis was looking at, including anything private on your screen", Toggle(d.KeepActivityScreenshots, v => Do(s => s.KeepActivityScreenshots = v)))),
        };
        var recent = Enumerable.Reverse(activity.Entries).Take(100).ToList();
        if (recent.Count == 0) items.Add(Note("Nothing recorded yet."));
        else
        {
            var clear = Outline("Delete all", () =>
            {
                activity.Clear();
                Redraw();
            });
            clear.HorizontalAlignment = HorizontalAlignment.Left;
            clear.Margin = new Thickness(0, 0, 0, 18);
            items.Add(clear);
            items.Add(Card(recent.Select(entry =>
            {
                var lines = new[] { entry.Failure, "For: " + entry.Request, entry.Date.ToString("G", CultureInfo.CurrentCulture) }.Where(l => l is not null);
                var path = activity.ScreenshotPath(entry);
                return Row((entry.Failure is null ? "✓  " : "✕  ") + entry.Summary, string.Join("\n", lines), path is null ? null : Outline("Screenshot", () => OpenFolderOrFile(path)));
            }).ToArray()));
        }
        items.Add(Note($"Saved only on this PC, in files only your account can read, and limited to the latest {ActivityStore.MaxEntries} steps."));
        return Stack(items.ToArray());
    }

    private UIElement SafetyPage()
    {
        var policy = settings.Data.AppPolicy;
        var running = ActionRunner.RunningAppNames().OrderBy(n => n, StringComparer.OrdinalIgnoreCase).ToList();

        UIElement AppList(string title, List<string> apps)
        {
            var rows = new List<UIElement>
            {
                Row(title, null, Picker(running.Where(r => !apps.Contains(r)).Select(r => (r, r)).Prepend(("", "Add a running app")), "", app =>
                {
                    if (app.Length == 0) return;
                    Do(_ => apps.Add(app));
                    QueueRedraw();
                })),
            };
            rows.AddRange(apps.ToList().Select(app => Row(app, null, Outline("Remove", () =>
            {
                Do(_ => apps.Remove(app));
                Redraw();
            }))));
            return Card(rows.ToArray());
        }

        var items = new List<UIElement>
        {
            Card(Row("Only use the apps I list", "Jarvis won't click or type anywhere else", Toggle(policy.OnlyAllowed, v => Do(_ => policy.OnlyAllowed = v)))),
        };
        if (policy.OnlyAllowed) items.Add(AppList("Apps Jarvis can use", policy.Allowed));
        items.Add(AppList("Apps Jarvis must never use", policy.Blocked));
        items.Add(Note("These lists cover clicking and typing. Jarvis can still open and quit these apps when you ask. Offers of help also skip apps you've blocked. Built-in protections for terminals, password fields, Windows Settings, the Run box and security prompts always apply, and Windows itself stops Jarvis from using apps running as administrator."));
        return Stack(items.ToArray());
    }

    private UIElement SetupPage()
    {
        var mic = MicrophoneAllowed;
        UIElement speech;
        if (SpeechModel.IsInstalled) speech = Row("Speech model", "Turns what you say into text, on this PC", new TextBlock { Text = "✓ Installed", FontSize = 12, Foreground = Secondary });
        else if (SpeechModel.IsInstalling) speech = Row("Speech model", SpeechModel.Status);
        else speech = Row("Speech model", SpeechModel.Status.Length > 0 ? SpeechModel.Status : $"Turns what you say into text, on this PC. Downloads about {SpeechModel.Megabytes} MB from Hugging Face, and checks it before installing", Outline("Download", () => _ = SpeechModel.Install()));

        return Stack(
            Card(
                speech,
                Row("Microphone", mic ? "Hears you when you talk to Jarvis" : "Turn on microphone access for desktop apps, in Windows Settings", mic
                    ? new TextBlock { Text = "✓ Allowed", FontSize = 12, Foreground = Secondary }
                    : Outline("Open Settings", () => OpenFolderOrFile("ms-settings:privacy-microphone"))),
                Row("Screen, mouse and keyboard", "Windows doesn't ask permission for these. Your screen is only read when you ask something, and the mouse and keyboard only used as you've allowed on the General and Safety pages", new TextBlock { Text = "✓ Ready", FontSize = 12, Foreground = Secondary }),
                Row("Calendar, tasks and contacts", NativeServices.HasOutlook ? "Uses classic Outlook when you ask. Optional" : "These need classic Outlook, which isn't installed. The new Outlook has no way for other apps to reach them. Optional", new TextBlock { Text = NativeServices.HasOutlook ? "✓ Found" : "Not available", FontSize = 12, Foreground = Secondary })),
            Note("A screenshot of each display goes to your chosen AI only when you ask something."));
    }
}

/// <summary>Opening Jarvis at sign-in, kept where Windows looks for it, so it's read back from there rather than stored here.</summary>
public static class AutoStart
{
    private const string KeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run", Name = "Jarvis";

    public static bool IsOn
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(KeyPath);
            return key?.GetValue(Name) is not null;
        }
    }

    public static void Set(bool on)
    {
        using var key = Registry.CurrentUser.CreateSubKey(KeyPath);
        if (on) key.SetValue(Name, $"\"{Environment.ProcessPath}\"");
        else key.DeleteValue(Name, throwOnMissingValue: false);
    }
}
