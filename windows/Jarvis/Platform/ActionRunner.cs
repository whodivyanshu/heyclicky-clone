using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using Microsoft.Win32;

namespace Jarvis;

public sealed record ActionResult(string Summary, string? Failure = null, bool Retryable = false, string? Data = null);

/// <summary>Carries out the actions a reply asks for. Runs on the UI thread, apart from the waits.</summary>
public static class ActionRunner
{
    public static Func<AppPolicy> Policy = () => new AppPolicy();

    private const int KeyboardSettleMs = 150, BetweenCharactersMs = 8;

    public static string Progress(ActionTag tag) => tag.Kind switch
    {
        "OPEN_APP" => $"Opening {tag.Value}…",
        "QUIT_APP" => $"Quitting {tag.Value}…",
        "OPEN_URL" => $"Opening {Core.SplitUrl(tag.Value).Address}…",
        "FIND_FILE" => $"Searching for {tag.Value}…",
        "TYPE" => "Typing…",
        "KEY" => $"Pressing {tag.Value}…",
        "COPY" => "Copying…",
        "PASTE" => "Pasting…",
        "EVENTS" => "Checking your calendar…",
        "REMINDERS" => "Checking your tasks…",
        "CONTACT" => $"Looking up {tag.Value}…",
        "ADD_EVENT" => "Adding that to your calendar…",
        "ADD_REMINDER" => "Adding that task…",
        "DRAFT_MAIL" => "Starting that email…",
        "SHORTCUT" => $"Running {tag.Value}…",
        "RECALL" => "Searching your screen memory…",
        _ => "",
    };

    public static async Task<ActionResult> Run(ActionTag tag, CancellationToken cancel)
    {
        switch (tag.Kind)
        {
            case "OPEN_APP": return OpenApp(tag.Value);
            case "QUIT_APP": return QuitApp(tag.Value);
            case "OPEN_URL": return OpenUrl(tag.Value);
            case "FIND_FILE": return await FindFile(tag.Value, cancel);
            case "TYPE": return await Type(tag.Value, cancel);
            case "KEY": return await Press(tag.Value, cancel);
            case "COPY": return Copy(tag.Value);
            case "PASTE": return await Paste(tag.Value, cancel);
            case "EVENTS": case "REMINDERS": case "CONTACT": case "ADD_EVENT": case "ADD_REMINDER": case "DRAFT_MAIL": case "SHORTCUT":
                return await NativeServices.Run(tag);
            default: return new ActionResult("");
        }
    }

    // MARK: Input

    private static Win32.INPUT Key(ushort vk, bool down, bool extended = false) => new()
    {
        Type = Win32.INPUT_KEYBOARD,
        Data = new Win32.INPUTUNION { Keyboard = new Win32.KEYBDINPUT { Vk = vk, Flags = (down ? 0u : Win32.KEYEVENTF_KEYUP) | (extended ? Win32.KEYEVENTF_EXTENDEDKEY : 0u) } },
    };

    private static Win32.INPUT Unicode(char unit, bool down) => new()
    {
        Type = Win32.INPUT_KEYBOARD,
        Data = new Win32.INPUTUNION { Keyboard = new Win32.KEYBDINPUT { Scan = unit, Flags = Win32.KEYEVENTF_UNICODE | (down ? 0u : Win32.KEYEVENTF_KEYUP) } },
    };

    private static Win32.INPUT Mouse(uint flags) => new()
    {
        Type = Win32.INPUT_MOUSE,
        Data = new Win32.INPUTUNION { Mouse = new Win32.MOUSEINPUT { Flags = flags } },
    };

    /// <summary>A short count means Windows refused some of it. The hotkey monitor ignores key state meanwhile, so these don't look like the user.</summary>
    private static bool Send(params Win32.INPUT[] inputs)
    {
        HotkeyMonitor.IsInjecting = true;
        try { return Win32.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Win32.INPUT>()) == inputs.Length; }
        finally { HotkeyMonitor.IsInjecting = false; }
    }

    /// <summary>A key they're holding could turn a typed letter into a shortcut. Waits briefly for it to be let go.</summary>
    private static async Task<bool> WaitForModifiersReleased(CancellationToken cancel)
    {
        for (var i = 0; i < 40; i++)
        {
            if (!Win32.IsDown(Win32.VK_CONTROL) && !Win32.IsDown(Win32.VK_MENU) && !Win32.IsDown(Win32.VK_SHIFT) && !Win32.IsDown(Win32.VK_LWIN) && !Win32.IsDown(Win32.VK_RWIN)) return true;
            await Task.Delay(50, cancel);
        }
        return false;
    }

    private static readonly ActionResult HeldKeys = new("Didn't use the keyboard", "A key was being held down, so I stopped before typing.");

    // MARK: Clicks

    /// <summary>The top-level window under a point, leaving out Jarvis's own click-through windows.</summary>
    private static ForegroundApp? WindowAt(int x, int y)
    {
        var window = Win32.GetAncestor(Win32.WindowFromPoint(new Win32.POINT { X = x, Y = y }), Win32.GA_ROOT);
        return ForegroundApp.Of(window);
    }

    /// <summary>Clicks at a point, then puts the cursor back where it was.</summary>
    public static async Task<ActionResult> Click(int x, int y, string? label, CancellationToken cancel)
    {
        var name = label ?? "that";
        if (Win32.IsDesktopSecure()) return new ActionResult($"Left that to you", "A secure Windows prompt is on screen, so that one's yours to do.");
        var owner = WindowAt(x, y);
        if (owner is not null)
        {
            if (owner.ProcessName.Length == 0)
                return new ActionResult("Left that to you", "I can't tell which app that is, so that one's yours to do.");
            // Windows drops input aimed at these without saying so, which would look like a click that worked.
            if (owner.IsElevated)
                return new ActionResult($"Left {owner.DisplayName} to you", $"{owner.DisplayName} is running as administrator, so Windows won't let me click in it.");
            if (owner.IsJarvis)
                return new ActionResult("Left that to you", "I don't click in my own windows, so that one's yours to do.");
            if (!Core.PolicyPermits(Policy(), owner.DisplayName))
                return new ActionResult($"Left {owner.DisplayName} to you", $"You've told me not to use {owner.DisplayName}, so that one's yours to do.");
            if (Core.RefusesClick(owner.ProcessName, owner.Title))
                return new ActionResult($"Left {owner.DisplayName} to you", $"I don't click in {owner.DisplayName}, so that one's yours to do.");
            // A window in the background may only come forward on its first click, so bring it forward now.
            if (Win32.GetForegroundWindow() != owner.Window)
            {
                Win32.SetForegroundWindow(owner.Window);
                await Task.Delay(200, cancel);
            }
        }
        cancel.ThrowIfCancellationRequested();

        var (originalX, originalY) = Win32.CursorPosition();
        // Moving first gives lists and buttons a chance to react to the hover, as they would for a person.
        Win32.SetCursorPos(x, y);
        await Task.Delay(80, cancel);
        // The cursor being here can wake the island, so what's under it now has to be checked, or the click could land on Jarvis's own buttons.
        if (WindowAt(x, y)?.IsJarvis != false)
        {
            Win32.SetCursorPos(originalX, originalY);
            return new ActionResult("Left that to you", "Something of mine was in the way, so I didn't click.", Retryable: true);
        }
        if (!Send(Mouse(Win32.MOUSEEVENTF_LEFTDOWN)))
        {
            Win32.SetCursorPos(originalX, originalY);
            return new ActionResult($"Couldn't click {name}", "Windows wouldn't let me click there. It may be running as administrator.");
        }
        try { await Task.Delay(50, CancellationToken.None); }
        finally
        {
            Send(Mouse(Win32.MOUSEEVENTF_LEFTUP));
            Win32.SetCursorPos(originalX, originalY);
        }
        return new ActionResult($"Clicked {name}");
    }

    // MARK: Keyboard

    /// <summary>
    /// Why the keyboard can't be used right now. It's checked again during typing, because focus can move. It refuses
    /// when it can't tell what's in front, since a keystroke sent blind could land anywhere.
    /// </summary>
    private static ActionResult? KeyboardRefusal()
    {
        if (Win32.IsDesktopSecure()) return new ActionResult("Left that to you", "A secure Windows prompt is on screen, so that one's yours to do.");
        var front = ForegroundApp.Current();
        if (front is null || front.ProcessName.Length == 0)
            return new ActionResult("Didn't type", "I couldn't tell which app would get the keys, so I stopped.");
        // Windows drops input aimed at these without saying so, which would look like typing that worked.
        if (front.IsElevated)
            return new ActionResult($"Left {front.DisplayName} to you", $"{front.DisplayName} is running as administrator, so Windows won't let me type in it.");
        // Jarvis's own Settings window holds the API key.
        if (front.IsJarvis || Core.RefusesKeyboard(front.ProcessName, front.Title))
            return new ActionResult($"Left {front.DisplayName} to you", $"I don't type in {front.DisplayName}, so that one's yours to do.");
        if (!Core.PolicyPermits(Policy(), front.DisplayName))
            return new ActionResult($"Left {front.DisplayName} to you", $"You've told me not to use {front.DisplayName}, so that one's yours to do.");
        return null;
    }

    /// <summary>Unlike a Mac there's no system-wide signal, so this asks the focused control, and not knowing counts as a password field.</summary>
    private static ActionResult? PasswordRefusal()
    {
        return UIInspector.FocusIsPassword() == false
            ? null
            : new ActionResult("Left that field to you", "That looks like a password field, so that one's yours to type.");
    }

    private static ActionResult? TerminalRefusal()
    {
        return Core.IsTerminalPane(UIInspector.CurrentKeyContext())
            ? new ActionResult("Left the terminal to you", "The keyboard is in a terminal, where typing could run a command, so that one's yours to do.")
            : null;
    }

    private static async Task<ActionResult> Type(string text, CancellationToken cancel)
    {
        if (Core.TypableText(text) is not { } typable) return new ActionResult("Nothing to type");
        await Task.Delay(KeyboardSettleMs, cancel);
        if ((PasswordRefusal() ?? TerminalRefusal()) is { } refusal) return refusal;
        if (!await WaitForModifiersReleased(cancel)) return HeldKeys;

        var checkedAt = 0;
        var enumerator = System.Globalization.StringInfo.GetTextElementEnumerator(typable);
        while (enumerator.MoveNext())
        {
            cancel.ThrowIfCancellationRequested();
            if (KeyboardRefusal() is { } stopped) return stopped;
            // Reading the focused control costs too much for every letter, so it's done every so often.
            if (++checkedAt % 16 == 0 && PasswordRefusal() is { } password) return password;
            var units = (string)enumerator.Current;
            var inputs = new List<Win32.INPUT>();
            foreach (var unit in units) inputs.Add(Unicode(unit, true));
            foreach (var unit in units) inputs.Add(Unicode(unit, false));
            if (!Send(inputs.ToArray()))
                return new ActionResult("Couldn't type", "Windows wouldn't let me type there. It may be running as administrator.");
            await Task.Delay(BetweenCharactersMs, cancel);
        }
        return new ActionResult($"Typed \"{(typable.Length > 40 ? typable[..40] : typable)}\"");
    }

    /// <summary>Windows key codes for the names the core's key parser allows. Anything else was refused before reaching here.</summary>
    private static (ushort Vk, bool Extended)? VirtualKey(string key)
    {
        if (key.Length == 1)
        {
            var c = key[0];
            if (c is >= 'a' and <= 'z') return ((ushort)char.ToUpperInvariant(c), false);
            if (c is >= '0' and <= '9') return (c, false);
            return c switch
            {
                '=' => (0xBB, false), '-' => (0xBD, false), ',' => (0xBC, false), '.' => (0xBE, false), '/' => (0xBF, false),
                ';' => (0xBA, false), '`' => (0xC0, false), '\'' => (0xDE, false),
                _ => null,
            };
        }
        if (key.Length is 2 or 3 && key[0] == 'f' && int.TryParse(key[1..], out var number) && number is >= 1 and <= 12) return ((ushort)(0x70 + number - 1), false);
        return key switch
        {
            "return" or "enter" => (0x0D, false),
            "tab" => (0x09, false),
            "space" => (0x20, false),
            "backspace" => (0x08, false),
            "delete" or "forwarddelete" => (0x2E, true),
            "left" => (0x25, true), "up" => (0x26, true), "right" => (0x27, true), "down" => (0x28, true),
            "home" => (0x24, true), "end" => (0x23, true), "pageup" => (0x21, true), "pagedown" => (0x22, true),
            _ => null,
        };
    }

    private static async Task<ActionResult> Press(string text, CancellationToken cancel)
    {
        if (Core.ParseKey(text) is not { } press || VirtualKey(press.Key) is not { } key)
            return new ActionResult($"Didn't press {text}", $"I can't press {text} for you, so that one's yours to do.");
        await Task.Delay(KeyboardSettleMs, cancel);
        cancel.ThrowIfCancellationRequested();
        if ((KeyboardRefusal() ?? TerminalRefusal()) is { } refusal) return refusal;
        if (!await WaitForModifiersReleased(cancel)) return HeldKeys;

        var modifiers = new List<ushort>();
        if (press.Control) modifiers.Add(Win32.VK_CONTROL);
        if (press.Shift) modifiers.Add(Win32.VK_SHIFT);
        if (press.Alt) modifiers.Add(Win32.VK_MENU);
        var inputs = new List<Win32.INPUT>();
        inputs.AddRange(modifiers.Select(m => Key(m, true)));
        inputs.Add(Key(key.Vk, true, key.Extended));
        inputs.Add(Key(key.Vk, false, key.Extended));
        inputs.AddRange(Enumerable.Reverse(modifiers).Select(m => Key(m, false)));
        return Send(inputs.ToArray())
            ? new ActionResult($"Pressed {text}")
            : new ActionResult($"Couldn't press {text}", "Windows wouldn't let me press keys there. It may be running as administrator.");
    }

    private static bool SendPasteShortcut() => Send(Key(Win32.VK_CONTROL, true), Key(0x56, true), Key(0x56, false), Key(Win32.VK_CONTROL, false));

    // MARK: Clipboard

    /// <summary>Other apps hold the clipboard open briefly, which makes it fail for a moment.</summary>
    private static bool Retrying(Action work)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try { work(); return true; }
            catch (ExternalException) { Thread.Sleep(30); }
        }
        return false;
    }

    private static ActionResult Copy(string text) => Retrying(() => Clipboard.SetText(text))
        ? new ActionResult("Copied to the clipboard")
        : new ActionResult("Couldn't copy", "The clipboard was busy, so I couldn't copy that.");

    /// <summary>The clipboard's text, unless the app that copied it marked it as a secret, as password managers do.</summary>
    public static string? ClipboardText()
    {
        string? text = null;
        Retrying(() =>
        {
            // Set by password managers, and by Windows' own clipboard rules, to keep text out of history and sync.
            var data = Clipboard.GetDataObject();
            if (data is null || data.GetDataPresent("ExcludeClipboardContentFromMonitorProcessing") || data.GetDataPresent("Clipboard Viewer Ignore")) return;
            if (Clipboard.ContainsText()) text = Clipboard.GetText();
        });
        return Core.LimitedContext(text);
    }

    private static async Task<ActionResult> Paste(string text, CancellationToken cancel)
    {
        if ((KeyboardRefusal() ?? PasswordRefusal()) is { } first) return first;
        if (!Retrying(() => Clipboard.SetText(text))) return new ActionResult("Couldn't paste", "The clipboard was busy, so I couldn't paste that.");
        await Task.Delay(KeyboardSettleMs, cancel);
        cancel.ThrowIfCancellationRequested();
        // Focus can move during the wait.
        if ((KeyboardRefusal() ?? PasswordRefusal() ?? TerminalRefusal()) is { } refusal) return refusal;
        if (!await WaitForModifiersReleased(cancel)) return HeldKeys;
        return SendPasteShortcut()
            ? new ActionResult($"Pasted \"{(text.Length > 40 ? text[..40] : text)}\"")
            : new ActionResult("Couldn't paste", "Windows wouldn't let me paste there. It may be running as administrator.");
    }

    /// <summary>
    /// Pastes what they just dictated, then puts their clipboard back. Unlike Jarvis's own typing this is allowed in
    /// terminals, because it's their words and Return isn't pressed. Password fields are still refused.
    /// </summary>
    public static async Task<ActionResult> InsertDictation(string text, CancellationToken cancel)
    {
        var passwordField = new ActionResult("Left that field to you", "That looks like a password field, so I didn't paste into it.");
        if (Win32.IsDesktopSecure() || UIInspector.FocusIsPassword() != false) return passwordField;

        IDataObject? saved = null;
        Retrying(() => saved = CopyOfClipboard());
        DataObject item = new();
        item.SetText(text);
        // Asks clipboard history and sync not to keep this, since it's only passing through.
        item.SetData("ExcludeClipboardContentFromMonitorProcessing", new MemoryStream(new byte[4]));
        item.SetData("CanIncludeInClipboardHistory", new MemoryStream(new byte[4]));
        if (!Retrying(() => Clipboard.SetDataObject(item, copy: true))) return new ActionResult("Couldn't paste", "The clipboard was busy, so I couldn't paste that.");

        await Task.Delay(60, cancel);
        if (UIInspector.FocusIsPassword() != false)
        {
            Restore(saved, text);
            return passwordField;
        }
        if (!await WaitForModifiersReleased(cancel))
        {
            Restore(saved, text);
            return HeldKeys;
        }
        var sent = SendPasteShortcut();
        // The app reads the clipboard when it handles the paste, so this has to wait for that.
        await Task.Delay(500, CancellationToken.None);
        Restore(saved, text);
        return sent ? new ActionResult("Dictated") : new ActionResult("Couldn't paste", "Windows wouldn't let me paste there. It may be running as administrator.");
    }

    /// <summary>A real copy, because what the clipboard hands out stops working once something else is put there.</summary>
    private static DataObject? CopyOfClipboard()
    {
        var current = Clipboard.GetDataObject();
        if (current is null) return null;
        var copy = new DataObject();
        foreach (var format in current.GetFormats(autoConvert: false))
        {
            try
            {
                if (current.GetData(format, autoConvert: false) is { } data) copy.SetData(format, data);
            }
            catch (Exception problem) when (problem is ExternalException or OutOfMemoryException or InvalidOperationException) { }
        }
        return copy;
    }

    private static void Restore(IDataObject? saved, string ours)
    {
        Retrying(() =>
        {
            // If they've copied something else since, that's what they want to keep.
            if (!Clipboard.ContainsText() || Clipboard.GetText() != ours) return;
            if (saved is null) Clipboard.Clear();
            else Clipboard.SetDataObject(saved, copy: true);
        });
    }

    // MARK: Apps

    /// <summary>Installed apps from the Start menu, which is where Windows itself keeps them. A user's copy comes before a system one.</summary>
    private static Dictionary<string, string> InstalledApps()
    {
        var apps = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var folders = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.StartMenu),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu),
            Environment.GetFolderPath(Environment.SpecialFolder.Desktop),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonDesktopDirectory),
        };
        foreach (var folder in folders)
        {
            foreach (var link in LinksIn(folder))
            {
                var name = Path.GetFileNameWithoutExtension(link);
                if (name.Contains("uninstall", StringComparison.OrdinalIgnoreCase)) continue;
                apps.TryAdd(name, link);
            }
        }
        foreach (var (name, id) in PackagedApps()) apps.TryAdd(name, "shell:AppsFolder\\" + id);
        return apps;
    }

    private static IEnumerable<string> LinksIn(string folder)
    {
        try
        {
            if (!Directory.Exists(folder)) return Array.Empty<string>();
            var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true };
            return Directory.EnumerateFiles(folder, "*.lnk", options).Concat(Directory.EnumerateFiles(folder, "*.appref-ms", options)).ToList();
        }
        catch (Exception problem) when (problem is IOException or UnauthorizedAccessException) { return Array.Empty<string>(); }
    }

    /// <summary>Store apps such as Calculator have no shortcut file. Windows lists them all in its Apps folder.</summary>
    private static List<(string Name, string Id)> PackagedApps()
    {
        var apps = new List<(string, string)>();
        try
        {
            var shellType = System.Type.GetTypeFromProgID("Shell.Application");
            if (shellType is null) return apps;
            dynamic shell = Activator.CreateInstance(shellType)!;
            dynamic folder = shell.NameSpace("shell:AppsFolder");
            foreach (dynamic item in folder.Items())
            {
                string id = item.Path;
                string name = item.Name;
                // Only packaged apps. The rest came from the shortcuts above, and an entry here could be any file.
                if (id.Contains('!')) apps.Add((name, id));
            }
        }
        catch (Exception problem) when (problem is COMException or InvalidCastException or Microsoft.CSharp.RuntimeBinder.RuntimeBinderException)
        {
            Log.Write($"Listing apps failed: {problem.GetType().Name}");
        }
        return apps;
    }

    private static Dictionary<string, string>? appCache;
    private static DateTime appCacheTime;

    private static Dictionary<string, string> Apps()
    {
        if (appCache is null || DateTime.UtcNow - appCacheTime > TimeSpan.FromMinutes(5))
        {
            appCache = InstalledApps();
            appCacheTime = DateTime.UtcNow;
        }
        return appCache;
    }

    public static List<string> InstalledAppNames() => Apps().Keys.ToList();

    /// <summary>Apps that could be asked to quit, meaning those with a window. That never includes Jarvis.</summary>
    public static List<(string Name, Process Process)> RunningApps()
    {
        var apps = new List<(string, Process)>();
        foreach (var process in Process.GetProcesses())
        {
            if (process.Id == Environment.ProcessId || process.SessionId != Process.GetCurrentProcess().SessionId)
            {
                process.Dispose();
                continue;
            }
            try
            {
                if (process.MainWindowHandle == IntPtr.Zero)
                {
                    process.Dispose();
                    continue;
                }
                apps.Add((ForegroundApp.Names((uint)process.Id).Display, process));
            }
            catch (Exception problem) when (problem is InvalidOperationException or Win32Exception) { process.Dispose(); }
        }
        return apps;
    }

    public static List<string> RunningAppNames()
    {
        var running = RunningApps();
        var names = running.Select(a => a.Name).Where(n => n.Length > 0).Distinct().ToList();
        foreach (var (_, process) in running) process.Dispose();
        return names;
    }

    private static bool OpenTarget(string target)
    {
        try
        {
            // The shell opens these the way a click would.
            using var process = Process.Start(new ProcessStartInfo { FileName = target, UseShellExecute = true });
            return true;
        }
        catch (Exception problem) when (problem is Win32Exception or InvalidOperationException or FileNotFoundException) { return false; }
    }

    public static string? FindApp(string query)
    {
        var apps = Apps();
        return Core.BestApp(query, apps.Keys) is { } match ? match : null;
    }

    private static ActionResult OpenApp(string query)
    {
        if (FindApp(query) is not { } name)
            return new ActionResult($"Couldn't find {query}", $"I couldn't find an app called {query} on this PC.", Retryable: true);
        return OpenTarget(Apps()[name])
            ? new ActionResult($"Opened {name}")
            : new ActionResult($"Couldn't open {name}", $"{name} wouldn't open.", Retryable: true);
    }

    private static ActionResult QuitApp(string query)
    {
        var running = RunningApps();
        try
        {
            var match = Core.BestApp(query, running.Select(a => a.Name).Where(n => n.Length > 0));
            var found = running.Where(a => a.Name == match).ToList();
            if (match is null || found.Count == 0)
                return new ActionResult($"{query} isn't running", $"{query} isn't running.", Retryable: true);
            // A normal quit, so the app can still ask about unsaved work.
            foreach (var (_, process) in found) process.CloseMainWindow();
            return new ActionResult($"Asked {match} to quit");
        }
        finally
        {
            foreach (var (_, process) in running) process.Dispose();
        }
    }

    // MARK: Web

    private static ActionResult OpenUrl(string text)
    {
        var couldNotOpen = new ActionResult("Couldn't open that address", "I couldn't open that address.", Retryable: true);
        var (address, browser) = Core.SplitUrl(text);
        if (Core.WebUrl(address) is not { } url) return couldNotOpen;
        var host = new Uri(url).Host;
        if (browser is null) return OpenTarget(url) ? new ActionResult($"Opened {host}") : couldNotOpen;

        if (FindBrowser(browser) is not { } program)
            return new ActionResult($"Couldn't find {browser}", $"I couldn't find a browser called {browser} on this PC.", Retryable: true);
        try
        {
            var start = new ProcessStartInfo { FileName = program.Path, UseShellExecute = false };
            start.ArgumentList.Add(url);
            using var process = Process.Start(start);
            return new ActionResult($"Opened {host} in {program.Name}");
        }
        catch (Exception problem) when (problem is Win32Exception or InvalidOperationException)
        {
            return new ActionResult($"Couldn't open {program.Name}", $"{program.Name} wouldn't open that address.", Retryable: true);
        }
    }

    /// <summary>A close name match could be any app, and a web address should only ever go to a browser, so this only looks at what Windows has registered as one.</summary>
    private static (string Name, string Path)? FindBrowser(string query)
    {
        var browsers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var root in new[] { Registry.CurrentUser, Registry.LocalMachine })
        {
            using var key = root.OpenSubKey(@"SOFTWARE\Clients\StartMenuInternet");
            if (key is null) continue;
            foreach (var id in key.GetSubKeyNames())
            {
                using var browser = key.OpenSubKey(id);
                using var command = key.OpenSubKey(id + @"\shell\open\command");
                var name = browser?.GetValue(null) as string;
                var path = (command?.GetValue(null) as string)?.Trim().Trim('"');
                if (name is not null && path is not null && File.Exists(path)) browsers.TryAdd(name, path);
            }
        }
        return Core.BestApp(query, browsers.Keys) is { } match ? (match, browsers[match]) : null;
    }

    // MARK: Files

    /// <summary>Shows the best match in File Explorer without opening it, so nothing runs.</summary>
    private static async Task<ActionResult> FindFile(string query, CancellationToken cancel)
    {
        var path = await Task.Run(() => SearchHome(query, cancel), cancel);
        if (path is null)
            return new ActionResult($"Couldn't find {query}", $"I couldn't find a file matching {query}.", Retryable: true);
        using var explorer = Process.Start(new ProcessStartInfo { FileName = "explorer.exe", ArgumentList = { "/select," + path }, UseShellExecute = false });
        return new ActionResult($"Found {Path.GetFileName(path)}");
    }

    private static string? SearchHome(string query, CancellationToken cancel)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var words = query.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0) return null;
        var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.Hidden | FileAttributes.System | FileAttributes.ReparsePoint };
        var clock = Stopwatch.StartNew();
        string? best = null;
        try
        {
            foreach (var path in Directory.EnumerateFiles(home, "*", options))
            {
                cancel.ThrowIfCancellationRequested();
                if (clock.Elapsed.TotalSeconds > 15) break;
                if (path.Contains(@"\AppData\", StringComparison.OrdinalIgnoreCase) || path.Contains(@"\node_modules\", StringComparison.OrdinalIgnoreCase)) continue;
                var name = Path.GetFileName(path).ToLowerInvariant();
                if (!words.All(name.Contains)) continue;
                // The shortest name is the closest match, as in "report" finding report.pdf before report-old-final.pdf.
                if (best is null || name.Length < Path.GetFileName(best).Length) best = path;
            }
        }
        catch (Exception problem) when (problem is IOException or UnauthorizedAccessException) { }
        return best;
    }
}
