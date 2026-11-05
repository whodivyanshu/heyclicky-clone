using System;
using System.Windows.Threading;

namespace Jarvis;

/// <summary>
/// Watches for a held key combo and for Esc by polling key state, as the Mac app does. Polling can't block keys or
/// read typed text. A key hook would be able to see everything typed, and this has no need to.
/// </summary>
public sealed class HotkeyMonitor
{
    public Func<HotkeyChoice> Hotkey = () => HotkeyChoice.ControlAlt;
    public Func<DictationHotkey> DictationKey = () => DictationHotkey.Off;
    public Action OnPress = () => { };
    public Action OnRelease = () => { };
    public Action OnEscape = () => { };
    public Action OnDictationPress = () => { };
    public Action OnDictationRelease = () => { };

    /// <summary>
    /// Jarvis's own key presses change the state this reads, unlike on a Mac, so they're ignored while it's pressing keys.
    /// Otherwise pressing Ctrl+Alt+something for a job would look like the user holding the shortcut.
    /// </summary>
    public static volatile bool IsInjecting;

    private readonly DispatcherTimer timer = new(DispatcherPriority.Input) { Interval = TimeSpan.FromSeconds(1.0 / 30) };
    private bool isHeld, isDictationHeld, escapeWasDown;

    public void Start()
    {
        timer.Tick += (_, _) => Poll();
        timer.Start();
    }

    private static bool WinDown => Win32.IsDown(Win32.VK_LWIN) || Win32.IsDown(Win32.VK_RWIN);

    /// <summary>Exactly these modifiers, so a larger shortcut such as Ctrl+Alt+Shift doesn't count.</summary>
    private static bool Matches(int[] keys)
    {
        bool Wanted(int key) => Array.IndexOf(keys, key) >= 0;
        return Win32.IsDown(Win32.VK_CONTROL) == Wanted(Win32.VK_CONTROL)
            && Win32.IsDown(Win32.VK_MENU) == Wanted(Win32.VK_MENU)
            && Win32.IsDown(Win32.VK_SHIFT) == Wanted(Win32.VK_SHIFT)
            && WinDown == Wanted(-1);
    }

    private void Poll()
    {
        if (IsInjecting) return;

        var down = Matches(Hotkey().Keys());
        if (down != isHeld)
        {
            isHeld = down;
            if (down) OnPress(); else OnRelease();
        }

        var dictationKeys = DictationKey().Keys();
        var dictating = dictationKeys is not null && Matches(dictationKeys);
        if (dictating != isDictationHeld)
        {
            isDictationHeld = dictating;
            if (dictating) OnDictationPress(); else OnDictationRelease();
        }

        var escapeDown = Win32.IsDown(Win32.VK_ESCAPE);
        if (escapeDown && !escapeWasDown) OnEscape();
        escapeWasDown = escapeDown;
    }
}

/// <summary>Reports where the left button goes down, for walkthroughs. Clicks still go through to the app as usual.</summary>
public sealed class ClickMonitor : IDisposable
{
    private readonly Win32.LowLevelMouseProc callback;
    private IntPtr hook;
    private readonly Action<int, int> onClick;

    public ClickMonitor(Action<int, int> onClick)
    {
        this.onClick = onClick;
        callback = Hook;
        hook = Win32.SetWindowsHookEx(Win32.WH_MOUSE_LL, callback, Win32.GetModuleHandle(null), 0);
    }

    private IntPtr Hook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && (int)wParam == Win32.WM_LBUTTONDOWN)
        {
            var info = System.Runtime.InteropServices.Marshal.PtrToStructure<Win32.MSLLHOOKSTRUCT>(lParam);
            // Handled afterward, so a slow step can never hold up the mouse.
            Dispatcher.CurrentDispatcher.BeginInvoke(() => onClick(info.Point.X, info.Point.Y));
        }
        return Win32.CallNextHookEx(hook, code, wParam, lParam);
    }

    public void Dispose()
    {
        if (hook != IntPtr.Zero) Win32.UnhookWindowsHookEx(hook);
        hook = IntPtr.Zero;
    }
}
