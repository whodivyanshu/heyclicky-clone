using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Jarvis;

/// <summary>The Windows calls Jarvis needs. Screen coordinates are physical pixels, because the app is per-monitor DPI aware.</summary>
public static class Win32
{
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; public readonly int Width => Right - Left; public readonly int Height => Bottom - Top; }

    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr window, int index);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr window, int index, int value);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(IntPtr window, uint affinity);
    [DllImport("user32.dll")] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    public delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT point, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorEnumProc callback, IntPtr data);
    public delegate bool MonitorEnumProc(IntPtr monitor, IntPtr dc, IntPtr rect, IntPtr data);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);

    [DllImport("user32.dll")] public static extern IntPtr SetWindowsHookEx(int hook, LowLevelMouseProc callback, IntPtr module, uint thread);
    [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    public delegate IntPtr LowLevelMouseProc(int code, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetModuleHandle(string? name);
    [DllImport("kernel32.dll")] public static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder name, ref uint size);

    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int width, int height);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr dest, int x, int y, int width, int height, IntPtr source, int sx, int sy, uint rop);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr dc);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr window);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr window, IntPtr dc);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFO { public int Size; public RECT Monitor, Work; public uint Flags; }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint Type; public INPUTUNION Data; }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION
    {
        [FieldOffset(0)] public MOUSEINPUT Mouse;
        [FieldOffset(0)] public KEYBDINPUT Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int X, Y; public uint MouseData, Flags, Time; public IntPtr ExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort Vk, Scan; public uint Flags, Time; public IntPtr ExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSLLHOOKSTRUCT { public POINT Point; public uint MouseData, Flags, Time; public IntPtr ExtraInfo; }

    public const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
    public const uint KEYEVENTF_EXTENDEDKEY = 1, KEYEVENTF_KEYUP = 2, KEYEVENTF_UNICODE = 4;
    public const uint MOUSEEVENTF_LEFTDOWN = 2, MOUSEEVENTF_LEFTUP = 4;
    public const int WH_MOUSE_LL = 14, WM_LBUTTONDOWN = 0x201;
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x8000000;
    public const uint WDA_EXCLUDEFROMCAPTURE = 0x11;
    public const uint SWP_NOSIZE = 1, SWP_NOMOVE = 2, SWP_NOZORDER = 4, SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40;
    public const uint SRCCOPY = 0x00CC0020, CAPTUREBLT = 0x40000000;
    public const uint WM_CLOSE = 0x10;
    public const uint GA_ROOT = 2;
    public const uint MONITOR_DEFAULTTONEAREST = 2;
    public static readonly IntPtr HWND_TOPMOST = new(-1);

    public const int VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_ESCAPE = 0x1B, VK_LWIN = 0x5B, VK_RWIN = 0x5C;

    public static bool IsDown(int key) => (GetAsyncKeyState(key) & 0x8000) != 0;

    public static (int X, int Y) CursorPosition()
    {
        GetCursorPos(out var point);
        return (point.X, point.Y);
    }

    /// <summary>The window title, or an empty string if it has none.</summary>
    public static string WindowTitle(IntPtr window)
    {
        var text = new StringBuilder(512);
        return GetWindowText(window, text, text.Capacity) > 0 ? text.ToString() : "";
    }

    public static uint ProcessIdOf(IntPtr window)
    {
        GetWindowThreadProcessId(window, out var id);
        return id;
    }

    /// <summary>A locked screen, or a sign-in or UAC prompt on the secure desktop, can't be opened from here.</summary>
    public static bool IsDesktopSecure()
    {
        var desktop = OpenInputDesktop(0, false, 0x0100 /* DESKTOP_SWITCHDESKTOP */);
        if (desktop == IntPtr.Zero) return true;
        CloseDesktop(desktop);
        return false;
    }

    /// <summary>Marks a window as click-through, never focused, absent from Alt+Tab, and left out of screenshots.</summary>
    public static void MakeOverlay(IntPtr window, bool clickThrough)
    {
        int style = GetWindowLong(window, GWL_EXSTYLE) | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED;
        style = clickThrough ? style | WS_EX_TRANSPARENT : style & ~WS_EX_TRANSPARENT;
        SetWindowLong(window, GWL_EXSTYLE, style);
        SetWindowDisplayAffinity(window, WDA_EXCLUDEFROMCAPTURE);
    }

    public static void SetClickThrough(IntPtr window, bool clickThrough)
    {
        int style = GetWindowLong(window, GWL_EXSTYLE);
        int wanted = clickThrough ? style | WS_EX_TRANSPARENT : style & ~WS_EX_TRANSPARENT;
        if (wanted != style) SetWindowLong(window, GWL_EXSTYLE, wanted);
    }

    public static void SetActivatable(IntPtr window, bool activatable)
    {
        int style = GetWindowLong(window, GWL_EXSTYLE);
        int wanted = activatable ? style & ~WS_EX_NOACTIVATE : style | WS_EX_NOACTIVATE;
        if (wanted != style) SetWindowLong(window, GWL_EXSTYLE, wanted);
    }
}

/// <summary>What's in front of the user right now.</summary>
public sealed record ForegroundApp(uint ProcessId, IntPtr Window, string ProcessName, string DisplayName, string Title, bool IsElevated)
{
    public bool IsJarvis => ProcessId == (uint)Environment.ProcessId;

    public static ForegroundApp? Current() => Of(Win32.GetForegroundWindow());

    public static ForegroundApp? Of(IntPtr window)
    {
        if (window == IntPtr.Zero) return null;
        var id = Win32.ProcessIdOf(window);
        if (id == 0) return null;
        var (process, display, elevated) = Inspect(id);
        return new ForegroundApp(id, window, process, display, Win32.WindowTitle(window), elevated);
    }

    public static (string Process, string Display) Names(uint id)
    {
        var (process, display, _) = Inspect(id);
        return (process, display);
    }

    /// <summary>
    /// The process name, and the product name a person would use. Empty if the process has gone. Jarvis never runs as
    /// administrator, so a process whose module it can't read is one that does, or a protected part of Windows.
    /// </summary>
    private static (string Process, string Display, bool Elevated) Inspect(uint id)
    {
        try
        {
            using var process = Process.GetProcessById((int)id);
            var name = process.ProcessName;
            try
            {
                var description = process.MainModule?.FileVersionInfo.FileDescription;
                return (name, string.IsNullOrWhiteSpace(description) ? name : description.Trim(), false);
            }
            catch (Exception problem) when (problem is System.ComponentModel.Win32Exception or InvalidOperationException) { return (name, name, true); }
        }
        catch (Exception problem) when (problem is ArgumentException or InvalidOperationException) { return ("", "", false); }
    }
}
