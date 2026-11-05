using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace Jarvis;

/// <summary>
/// The companion that follows the cursor and flies to what the AI points at. On a Mac it's drawn on one panel per
/// display. Here it's one small window that moves, which crosses between displays by itself.
/// Positions are physical pixels with y running down.
/// </summary>
public sealed class OverlayController
{
    public Func<bool> ShowWhenIdle = () => true;
    public float Level;

    private const double WindowWidth = 760, WindowHeight = 440;
    private const double RingRadiusMin = 18, RingRadiusMax = 120, ListeningRingRadius = 21;
    private static readonly Color Accent = Color.FromRgb(255, 77, 110);

    private enum MotionKind { Follow, Flying, Parked }
    private MotionKind motion = MotionKind.Follow;
    private double fromX, fromY, toX, toY, flightDuration;
    private string? flightLabel;
    private double? flightRing;
    private DateTime flightStart;

    private double x, y, velocityX, velocityY, heading;
    private DateTime lastTick = DateTime.UtcNow, lastTopmost = DateTime.MinValue;
    private CompanionMode mode = CompanionMode.Idle;
    private string? caption;
    private DateTime? captionExpiry;
    private bool targetVisible;
    private double targetRadius;

    private readonly Window window;
    private readonly Canvas canvas = new() { Width = WindowWidth, Height = WindowHeight, IsHitTestVisible = false };
    private readonly Path dart;
    private readonly Ellipse ring, target;
    private readonly RotateTransform dartRotation = new();
    private readonly RotateTransform ringRotation = new();
    private readonly ScaleTransform ringScale = new();
    private readonly Border bubble;
    private readonly TextBlock bubbleText;
    private IntPtr handle;
    private readonly DispatcherTimer timer = new(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(16) };

    public OverlayController()
    {
        var accent = new SolidColorBrush(Accent);
        var geometry = new StreamGeometry();
        using (var context = geometry.Open())
        {
            // The tip sits at the origin, so positioning the shape positions the tip.
            context.BeginFigure(new Point(0, 0), true, true);
            context.LineTo(new Point(18, 7), true, false);
            context.LineTo(new Point(8, 9), true, false);
            context.LineTo(new Point(6, 19), true, false);
        }
        dart = new Path
        {
            Data = geometry, Fill = accent, Stroke = accent, StrokeThickness = 2.5, StrokeLineJoin = PenLineJoin.Round,
            RenderTransform = dartRotation,
            Effect = new System.Windows.Media.Effects.DropShadowEffect { Color = Colors.Black, Opacity = 0.3, BlurRadius = 6, ShadowDepth = 1, Direction = 270 },
        };
        var ringTransform = new TransformGroup();
        ringTransform.Children.Add(ringRotation);
        ringTransform.Children.Add(ringScale);
        ring = new Ellipse
        {
            Width = ListeningRingRadius * 2, Height = ListeningRingRadius * 2, Stroke = accent, StrokeThickness = 2.5,
            RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = ringTransform, Visibility = Visibility.Hidden,
        };
        target = new Ellipse { Stroke = accent, StrokeThickness = 2.5, Fill = new SolidColorBrush(Color.FromArgb(31, Accent.R, Accent.G, Accent.B)), Visibility = Visibility.Hidden };
        target.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(1, 0.45, TimeSpan.FromSeconds(0.7)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever });
        bubbleText = new TextBlock { Foreground = Brushes.White, FontSize = 13, FontWeight = FontWeights.Medium, TextWrapping = TextWrapping.Wrap, MaxWidth = 320 };
        bubble = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(235, 26, 26, 26)), CornerRadius = new CornerRadius(10),
            Padding = new Thickness(11, 7, 11, 7), Child = bubbleText, Visibility = Visibility.Hidden,
        };
        canvas.Children.Add(target);
        canvas.Children.Add(ring);
        canvas.Children.Add(dart);
        canvas.Children.Add(bubble);

        window = new Window
        {
            WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent, Topmost = true, ShowInTaskbar = false,
            ShowActivated = false, ResizeMode = ResizeMode.NoResize, Width = WindowWidth, Height = WindowHeight, Content = canvas, Title = "Jarvis pointer",
            Left = -32000, Top = -32000,
        };
    }

    public void Start()
    {
        window.SourceInitialized += (_, _) =>
        {
            handle = new WindowInteropHelper(window).Handle;
            Win32.MakeOverlay(handle, clickThrough: true);
        };
        window.Show();
        (x, y) = Win32.CursorPosition();
        timer.Tick += (_, _) => Tick();
        timer.Start();
    }

    public void SetMode(CompanionMode next)
    {
        mode = next;
        ring.Visibility = next is CompanionMode.Listening or CompanionMode.Thinking ? Visibility.Visible : Visibility.Hidden;
        ringRotation.BeginAnimation(RotateTransform.AngleProperty, null);
        dart.BeginAnimation(UIElement.OpacityProperty, null);
        ring.StrokeDashArray = null;
        if (next == CompanionMode.Thinking)
        {
            ring.StrokeDashArray = new DoubleCollection { 5.6, 4.8 };
            ringScale.ScaleX = ringScale.ScaleY = 1;
            ringRotation.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(0, -360, TimeSpan.FromSeconds(1.1)) { RepeatBehavior = RepeatBehavior.Forever });
        }
        else if (next == CompanionMode.Speaking)
        {
            dart.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(1, 0.6, TimeSpan.FromSeconds(0.45)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever });
        }
    }

    /// <summary>A null `lasting` keeps the caption until it's replaced.</summary>
    public void SetCaption(string? text, double? lasting = null)
    {
        caption = text;
        captionExpiry = lasting is { } seconds ? DateTime.UtcNow.AddSeconds(seconds) : null;
    }

    /// <summary>A `ringRadius` marks the spot as a click target for a guided step. Returns how long the flight takes, in seconds.</summary>
    public double Fly(double targetX, double targetY, string? label, double? ringRadius = null)
    {
        var distance = Math.Sqrt(Math.Pow(targetX - x, 2) + Math.Pow(targetY - y, 2));
        var duration = Math.Min(Math.Max(distance / 1300, 0.4), 1.0);
        velocityX = velocityY = 0;
        targetVisible = false;
        SetCaption(null);
        motion = MotionKind.Flying;
        (fromX, fromY, toX, toY) = (x, y, targetX, targetY);
        (flightStart, flightDuration, flightLabel, flightRing) = (DateTime.UtcNow, duration, label, ringRadius);
        return duration;
    }

    public void ReturnToCursor()
    {
        motion = MotionKind.Follow;
        heading = 0;
        targetVisible = false;
        SetCaption(null);
    }

    private static double EaseInOut(double t)
    {
        t = Math.Min(Math.Max(t, 0), 1);
        return t * t * (3 - 2 * t);
    }

    /// <summary>A point on an arc. Long flights bow out more, within a limit. The arc rises, which is toward smaller y here.</summary>
    private static (double X, double Y) ArcPoint(double sx, double sy, double ex, double ey, double t)
    {
        double dx = ex - sx, dy = ey - sy;
        var distance = Math.Sqrt(dx * dx + dy * dy);
        if (distance <= 0.001) return (ex, ey);
        var bow = Math.Min(distance * 0.25, 160);
        double side = dx >= 0 ? 1 : -1;
        var controlX = (sx + ex) / 2 + side * dy / distance * bow;
        var controlY = (sy + ey) / 2 - side * dx / distance * bow;
        var u = 1 - t;
        return (u * u * sx + 2 * u * t * controlX + t * t * ex, u * u * sy + 2 * u * t * controlY + t * t * ey);
    }

    private void Tick()
    {
        var now = DateTime.UtcNow;
        var dt = Math.Min((now - lastTick).TotalSeconds, 0.05);
        lastTick = now;
        if (captionExpiry is { } expiry && now > expiry)
        {
            caption = null;
            captionExpiry = null;
        }

        switch (motion)
        {
            case MotionKind.Follow:
                // A spring trailing just below and to the right of the real cursor.
                var (mouseX, mouseY) = Win32.CursorPosition();
                const double stiffness = 260, damping = 30;
                velocityX += ((mouseX + 16 - x) * stiffness - velocityX * damping) * dt;
                velocityY += ((mouseY + 16 - y) * stiffness - velocityY * damping) * dt;
                x += velocityX * dt;
                y += velocityY * dt;
                heading *= 0.85;
                break;
            case MotionKind.Flying:
                var elapsed = (now - flightStart).TotalSeconds;
                var (nextX, nextY) = ArcPoint(fromX, fromY, toX, toY, EaseInOut(elapsed / flightDuration));
                double moveX = nextX - x, moveY = nextY - y;
                if (Math.Sqrt(moveX * moveX + moveY * moveY) > 0.5)
                {
                    // The dart's resting direction is up and to the left.
                    var wanted = Math.Atan2(moveY, moveX) + Math.PI * 0.75;
                    heading += Math.Atan2(Math.Sin(wanted - heading), Math.Cos(wanted - heading)) * 0.25;
                }
                (x, y) = (nextX, nextY);
                if (elapsed >= flightDuration)
                {
                    (x, y) = (toX, toY);
                    motion = MotionKind.Parked;
                    SetCaption(flightLabel);
                    if (flightRing is { } radius)
                    {
                        targetVisible = true;
                        targetRadius = Math.Min(Math.Max(radius, RingRadiusMin), RingRadiusMax);
                    }
                }
                break;
            case MotionKind.Parked:
                heading *= 0.8;
                break;
        }
        Render(now);
    }

    private void Render(DateTime now)
    {
        if (handle == IntPtr.Zero) return;
        var visible = mode != CompanionMode.Idle || ShowWhenIdle();
        var scale = VisualTreeHelper.GetDpi(window).DpiScaleX;
        // The window sits with the pointer at its center, and only the window moves.
        Win32.SetWindowPos(handle, IntPtr.Zero, (int)Math.Round(x - WindowWidth * scale / 2), (int)Math.Round(y - WindowHeight * scale / 2), 0, 0,
            Win32.SWP_NOSIZE | Win32.SWP_NOZORDER | Win32.SWP_NOACTIVATE);
        // Other always-on-top windows can come in front, so it takes its place again now and then.
        if (now - lastTopmost > TimeSpan.FromSeconds(1))
        {
            lastTopmost = now;
            Win32.SetWindowPos(handle, Win32.HWND_TOPMOST, 0, 0, 0, 0, Win32.SWP_NOSIZE | Win32.SWP_NOMOVE | Win32.SWP_NOACTIVATE);
        }

        double centerX = WindowWidth / 2, centerY = WindowHeight / 2;
        dart.Visibility = visible ? Visibility.Visible : Visibility.Hidden;
        Canvas.SetLeft(dart, centerX);
        Canvas.SetTop(dart, centerY);
        dartRotation.Angle = heading * 180 / Math.PI;

        Canvas.SetLeft(ring, centerX + 9 - ListeningRingRadius);
        Canvas.SetTop(ring, centerY + 10 - ListeningRingRadius);
        if (mode == CompanionMode.Listening) ringScale.ScaleX = ringScale.ScaleY = 1 + Level * 0.45;

        target.Visibility = targetVisible ? Visibility.Visible : Visibility.Hidden;
        if (targetVisible)
        {
            target.Width = target.Height = targetRadius * 2;
            Canvas.SetLeft(target, centerX - targetRadius);
            Canvas.SetTop(target, centerY - targetRadius);
        }
        UpdateBubble(visible ? caption : null, centerX, centerY, scale);
    }

    private void UpdateBubble(string? text, double anchorX, double anchorY, double scale)
    {
        if (string.IsNullOrEmpty(text))
        {
            bubble.Visibility = Visibility.Hidden;
            return;
        }
        if (bubbleText.Text != text) bubbleText.Text = text;
        bubble.Visibility = Visibility.Visible;
        bubble.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var size = bubble.DesiredSize;

        // Below and to the right of the dart, flipped to stay on this display.
        var display = ScreenCapture.Displays().FirstOrDefault(d => d.Contains((int)x, (int)y));
        var left = anchorX + 26;
        var top = anchorY + 26;
        if (display is not null)
        {
            if (x + (26 + size.Width + 8) * scale > display.X + display.Width) left = anchorX - size.Width - 12;
            if (y + (26 + size.Height + 8) * scale > display.Y + display.Height) top = anchorY - size.Height - 16;
        }
        Canvas.SetLeft(bubble, left);
        Canvas.SetTop(bubble, top);
    }
}
