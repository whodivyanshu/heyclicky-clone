using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading;
using System.Threading.Tasks;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace Jarvis;

public sealed record CapturedScreen(ScreenMap Map, byte[] Jpeg);

/// <summary>One display, in physical pixels.</summary>
public sealed record Display(int X, int Y, int Width, int Height, double Scale, int WorkTop, bool IsPrimary)
{
    public bool Contains(int x, int y) => x >= X && x < X + Width && y >= Y && y < Y + Height;
}

/// <summary>
/// Takes screenshots with GDI. Jarvis's own windows mark themselves WDA_EXCLUDEFROMCAPTURE, so they're left out.
/// Nothing on Windows asks permission for this, so it needs no setup.
/// </summary>
public static class ScreenCapture
{
    /// <summary>Keeps images within the size vision models accept without resizing them again, so coordinates match what the model saw.</summary>
    private const int MaxLongEdge = 1568;
    private const int ThumbWidth = 160, ThumbHeight = 100;
    private const long JpegQuality = 75;

    public static List<Display> Displays()
    {
        var displays = new List<Display>();
        Win32.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (monitor, _, _, _) =>
        {
            var info = new Win32.MONITORINFO { Size = System.Runtime.InteropServices.Marshal.SizeOf<Win32.MONITORINFO>() };
            if (Win32.GetMonitorInfo(monitor, ref info))
            {
                var scale = Win32.GetDpiForMonitor(monitor, 0, out var dpi, out _) == 0 ? dpi / 96.0 : 1.0;
                displays.Add(new Display(info.Monitor.Left, info.Monitor.Top, info.Monitor.Width, info.Monitor.Height, scale, info.Work.Top, (info.Flags & 1) != 0));
            }
            return true;
        }, IntPtr.Zero);
        return displays;
    }

    public static Display DisplayAtCursor()
    {
        var (x, y) = Win32.CursorPosition();
        var displays = Displays();
        return displays.FirstOrDefault(d => d.Contains(x, y)) ?? displays.First();
    }

    private static Bitmap Grab(Display display)
    {
        var bitmap = new Bitmap(display.Width, display.Height, PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        var target = graphics.GetHdc();
        var screen = Win32.GetDC(IntPtr.Zero);
        try
        {
            if (!Win32.BitBlt(target, 0, 0, display.Width, display.Height, screen, display.X, display.Y, Win32.SRCCOPY | Win32.CAPTUREBLT))
                throw new JarvisMessage("Couldn't capture the screen.");
        }
        finally
        {
            Win32.ReleaseDC(IntPtr.Zero, screen);
            graphics.ReleaseHdc(target);
        }
        return bitmap;
    }

    private static Bitmap Scaled(Bitmap source, int width, int height)
    {
        var result = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(result);
        graphics.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBilinear;
        graphics.DrawImage(source, 0, 0, width, height);
        return result;
    }

    private static byte[] Jpeg(Bitmap image)
    {
        var codec = ImageCodecInfo.GetImageEncoders().First(e => e.FormatID == ImageFormat.Jpeg.Guid);
        using var parameters = new EncoderParameters(1);
        parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, JpegQuality);
        using var stream = new MemoryStream();
        image.Save(stream, codec, parameters);
        return stream.ToArray();
    }

    /// <summary>Every display, with the cursor's display first as screen 1.</summary>
    public static Task<List<CapturedScreen>> CaptureAll()
    {
        var (mouseX, mouseY) = Win32.CursorPosition();
        var displays = Displays().OrderBy(d => d.Contains(mouseX, mouseY) ? 0 : 1).ToList();
        return Task.Run(() =>
        {
            var captured = new List<CapturedScreen>();
            foreach (var display in displays)
            {
                var (width, height) = Core.Fitted(display.Width, display.Height, MaxLongEdge);
                using var full = Grab(display);
                using var fitted = Scaled(full, width, height);
                captured.Add(new CapturedScreen(
                    new ScreenMap(captured.Count + 1, display.X, display.Y, display.Width, display.Height, width, height),
                    Jpeg(fitted)));
            }
            if (captured.Count == 0) throw new JarvisMessage("Couldn't capture the screen.");
            return captured;
        });
    }

    /// <summary>A tiny grayscale copy of every display, for telling whether the screen is still changing.</summary>
    public static Task<byte[]?> Thumbnail() => Task.Run<byte[]?>(() =>
    {
        try
        {
            var pixels = new List<byte>();
            foreach (var display in Displays())
            {
                using var full = Grab(display);
                using var small = Scaled(full, ThumbWidth, ThumbHeight);
                var data = small.LockBits(new Rectangle(0, 0, ThumbWidth, ThumbHeight), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                try
                {
                    var row = new byte[ThumbWidth * 4];
                    for (var y = 0; y < ThumbHeight; y++)
                    {
                        System.Runtime.InteropServices.Marshal.Copy(data.Scan0 + y * data.Stride, row, 0, row.Length);
                        for (var x = 0; x < ThumbWidth; x++)
                            pixels.Add((byte)((row[x * 4] * 29 + row[x * 4 + 1] * 150 + row[x * 4 + 2] * 77) >> 8));
                    }
                }
                finally { small.UnlockBits(data); }
            }
            return pixels.ToArray();
        }
        catch (Exception problem) when (problem is not OperationCanceledException)
        {
            Log.Write($"Thumbnail failed: {problem.GetType().Name}");
            return null;
        }
    });

    /// <summary>The text on the cursor's display, read by Windows on this PC.</summary>
    public static async Task<string?> ReadText()
    {
        var engine = OcrEngine.TryCreateFromUserProfileLanguages();
        if (engine is null) return null;
        var display = DisplayAtCursor();
        try
        {
            using var software = await Task.Run(async () =>
            {
                var (width, height) = Core.Fitted(display.Width, display.Height, Math.Min((int)OcrEngine.MaxImageDimension, 3000));
                using var full = Grab(display);
                using var fitted = Scaled(full, width, height);
                var data = fitted.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                try
                {
                    var bytes = new byte[width * height * 4];
                    for (var y = 0; y < height; y++)
                        System.Runtime.InteropServices.Marshal.Copy(data.Scan0 + y * data.Stride, bytes, y * width * 4, width * 4);
                    return await Task.FromResult(SoftwareBitmap.CreateCopyFromBuffer(bytes.AsBuffer(), BitmapPixelFormat.Bgra8, width, height, BitmapAlphaMode.Premultiplied));
                }
                finally { fitted.UnlockBits(data); }
            });
            var result = await engine.RecognizeAsync(software);
            return string.Join("\n", result.Lines.Select(l => l.Text));
        }
        catch (Exception problem)
        {
            Log.Write($"Reading the screen failed: {problem.GetType().Name}");
            return null;
        }
    }

    /// <summary>
    /// Waits for the result of an action to show, for at most `limit` seconds. `before` is how the screen looked
    /// before opening something: a new window can take a while to appear, and until it does the old screen looks settled.
    /// </summary>
    public static async Task WaitUntilSettled(CancellationToken cancel, byte[]? before = null, bool requiresChange = false, double atLeast = 0, double limit = 0)
    {
        var start = DateTime.UtcNow;
        double Elapsed() => (DateTime.UtcNow - start).TotalSeconds;
        await Task.Delay(TimeSpan.FromSeconds(atLeast), cancel);

        var previous = await Thumbnail();
        // Without a way to look, or a before picture to compare with, wait the full time.
        if (previous is null || (requiresChange && before is null))
        {
            await Task.Delay(TimeSpan.FromSeconds(Math.Max(limit - Elapsed(), 0)), cancel);
            return;
        }
        var changed = !requiresChange;
        while (Elapsed() < limit)
        {
            await Task.Delay(100, cancel);
            var current = await Thumbnail();
            if (current is null) return;
            if (before is not null && !Core.LooksSame(current, before)) changed = true;
            if (changed && Core.LooksSame(current, previous)) return;
            previous = current;
        }
    }
}
