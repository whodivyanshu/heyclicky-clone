using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace Jarvis;

public enum IslandPhase { Resting, Listening, Thinking, Speaking, Guiding, Confirming, Message, Offering }

/// <summary>Everything the island shows. The coordinator writes to it, and the window reads from it.</summary>
public sealed class IslandModel
{
    public event Action? Changed;

    private void Set<T>(ref T field, T value)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        Changed?.Invoke();
    }

    private IslandPhase phase = IslandPhase.Resting;
    private bool isOpen, isRecordingMeeting;
    private float level;
    private string transcript = "", reply = "", message = "", notice = "", activity = "", progress = "", confirmTitle = "", confirmDetail = "", offerTitle = "";
    private int guideStep;
    private IReadOnlyList<ChatTurn> conversation = Array.Empty<ChatTurn>();
    private string hotkeyName = "Ctrl + Alt";
    private CancellationTokenSource? restTask;

    public IslandPhase Phase => phase;
    public bool IsOpen { get => isOpen; set => Set(ref isOpen, value); }
    public float Level { get => level; set => Set(ref level, value); }
    public string Transcript { get => transcript; set => Set(ref transcript, value); }
    public string Reply { get => reply; set => Set(ref reply, value); }
    public string Message { get => message; set => Set(ref message, value); }
    public string Notice { get => notice; set => Set(ref notice, value); }
    public string Activity { get => activity; set => Set(ref activity, value); }
    public string Progress { get => progress; set => Set(ref progress, value); }
    public string ConfirmTitle { get => confirmTitle; set => Set(ref confirmTitle, value); }
    public string ConfirmDetail { get => confirmDetail; set => Set(ref confirmDetail, value); }
    public string OfferTitle { get => offerTitle; set => Set(ref offerTitle, value); }
    public bool IsRecordingMeeting { get => isRecordingMeeting; set => Set(ref isRecordingMeeting, value); }
    public int GuideStep { get => guideStep; set => Set(ref guideStep, value); }
    public IReadOnlyList<ChatTurn> Conversation { get => conversation; set { conversation = value; Changed?.Invoke(); } }
    public string HotkeyName { get => hotkeyName; set => Set(ref hotkeyName, value); }

    public Action<string> OnAsk = _ => { };
    public Action OnStop = () => { };
    public Action<bool> OnConfirm = _ => { };
    public Action OnOpenSettings = () => { };
    public Action OnAcceptOffer = () => { };
    public Action OnDismissOffer = () => { };

    public void Show(IslandPhase next)
    {
        restTask?.Cancel();
        restTask = null;
        Set(ref phase, next);
    }

    public void Rest()
    {
        Show(IslandPhase.Resting);
        Level = 0;
        Transcript = Reply = Message = Notice = Activity = Progress = ConfirmTitle = ConfirmDetail = OfferTitle = "";
    }

    /// <summary>Keeps what's on the island readable for a moment, then folds it away.</summary>
    public async void RestAfter(double seconds)
    {
        restTask?.Cancel();
        var mine = restTask = new CancellationTokenSource();
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(seconds), mine.Token);
            Rest();
        }
        catch (OperationCanceledException) { }
    }

    public void ShowMessage(string text, double lasting = 7)
    {
        Message = text;
        Show(IslandPhase.Message);
        RestAfter(lasting);
    }
}

public static class JarvisStyle
{
    public static readonly Color Amber = Color.FromRgb(255, 176, 59), Rose = Color.FromRgb(255, 77, 110), Violet = Color.FromRgb(140, 64, 242);
    public static readonly LinearGradientBrush Brand = Freeze(new LinearGradientBrush(new GradientStopCollection
    {
        new(Amber, 0), new(Rose, 0.5), new(Violet, 1),
    }, new Point(0, 0), new Point(1, 1)));
    public static readonly SolidColorBrush AmberBrush = Freeze(new SolidColorBrush(Amber));

    private static T Freeze<T>(T brush) where T : Freezable
    {
        brush.Freeze();
        return brush;
    }

    /// <summary>The four-point spark from the logo.</summary>
    public static Geometry Spark(double size)
    {
        double reach = size / 2, waist = reach * 0.22, c = size / 2;
        var geometry = new StreamGeometry();
        using (var context = geometry.Open())
        {
            context.BeginFigure(new Point(c, c - reach), true, true);
            context.QuadraticBezierTo(new Point(c + waist, c - waist), new Point(c + reach, c), true, false);
            context.QuadraticBezierTo(new Point(c + waist, c + waist), new Point(c, c + reach), true, false);
            context.QuadraticBezierTo(new Point(c - waist, c + waist), new Point(c - reach, c), true, false);
            context.QuadraticBezierTo(new Point(c - waist, c - waist), new Point(c, c - reach), true, false);
        }
        geometry.Freeze();
        return geometry;
    }

    public static Path SparkMark(double size) => new() { Data = Spark(size), Fill = Brand, Width = size, Height = size };

    private static readonly Style PlainButton = MakePlainButtonStyle();

    /// <summary>A button with no chrome of its own, which only shows what's put inside it.</summary>
    private static Style MakePlainButtonStyle()
    {
        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        var template = new ControlTemplate(typeof(Button)) { VisualTree = content };
        template.Seal();
        var style = new Style(typeof(Button));
        style.Setters.Add(new Setter(Control.TemplateProperty, template));
        style.Setters.Add(new Setter(FrameworkElement.CursorProperty, Cursors.Hand));
        style.Setters.Add(new Setter(UIElement.FocusableProperty, false));
        style.Seal();
        return style;
    }

    public static Button Plain(UIElement content, Action action, string? tooltip = null)
    {
        var button = new Button { Style = PlainButton, Content = content, ToolTip = tooltip };
        button.Click += (_, _) => action();
        return button;
    }

    public static Button Pill(string text, bool primary, Action action)
    {
        var label = new TextBlock { Text = text, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = primary ? Brushes.Black : Brushes.White, VerticalAlignment = VerticalAlignment.Center };
        var border = new Border
        {
            Background = primary ? Brushes.White : new SolidColorBrush(Color.FromArgb(36, 255, 255, 255)),
            CornerRadius = new CornerRadius(14), Height = 28, Padding = new Thickness(14, 0, 14, 0), Child = label,
        };
        return Plain(border, action);
    }
}

/// <summary>
/// The black pill at the top center of the screen. It stays click-through except over the island itself, follows the
/// display you're on, and opens on hover. It's drawn fresh when its model changes, apart from the animated parts.
/// </summary>
public sealed class IslandController
{
    private const double PanelWidth = 640, PanelHeight = 520, Shoulder = 10;
    private static readonly TimeSpan HoverOpenDelay = TimeSpan.FromSeconds(0.12), HoverCloseDelay = TimeSpan.FromSeconds(0.4);
    private static readonly string[] Suggestions = { "What's on my screen?", "Explain what I'm looking at", "Walk me through this app" };

    private readonly IslandModel model;
    private readonly AppSettings settings;
    private readonly Window window;
    private readonly Grid root = new();
    private readonly Border shell = new() { VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Center, Background = Brushes.Black, ClipToBounds = true };
    private readonly Border glow = new() { VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Center, Background = JarvisStyle.Brand, IsHitTestVisible = false, Effect = new System.Windows.Media.Effects.BlurEffect { Radius = 18 } };
    private readonly DispatcherTimer timer = new(DispatcherPriority.Input) { Interval = TimeSpan.FromSeconds(1.0 / 30) };
    private readonly DispatcherTimer animation = new(DispatcherPriority.Render) { Interval = TimeSpan.FromSeconds(1.0 / 30) };
    private IntPtr handle;
    private Display? current;
    private DateTime? hoverStarted, leftAt;
    private IntPtr focusBefore;
    private TextBox? composer;
    private string draft = "";
    private bool rebuilding, rebuildQueued;
    private bool wasOpen;
    private Path? spark;
    private StackPanel? bars;
    private StackPanel? dots;

    public IslandController(IslandModel model, AppSettings settings)
    {
        this.model = model;
        this.settings = settings;
        root.Children.Add(glow);
        root.Children.Add(shell);
        window = new Window
        {
            WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent, Topmost = true, ShowInTaskbar = false,
            ShowActivated = false, ResizeMode = ResizeMode.NoResize, Width = PanelWidth, Height = PanelHeight, Content = root, Title = "Jarvis",
            Left = -32000, Top = -32000, FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI"),
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
        Place(ScreenCapture.DisplayAtCursor());
        model.Changed += QueueRebuild;
        settings.Changed += QueueRebuild;
        Rebuild();
        timer.Tick += (_, _) => Tick();
        timer.Start();
        animation.Tick += (_, _) => Animate();
        animation.Start();
    }

    private void Place(Display display)
    {
        current = display;
        Win32.SetWindowPos(handle, Win32.HWND_TOPMOST,
            display.X + (int)((display.Width - PanelWidth * display.Scale) / 2), display.Y, 0, 0,
            Win32.SWP_NOSIZE | Win32.SWP_NOACTIVATE);
    }

    private bool IsVisible => model.IsOpen || model.Phase != IslandPhase.Resting || settings.Data.ShowIslandWhenIdle || model.IsRecordingMeeting;

    private void QueueRebuild()
    {
        // Several values often change together, and this waits for all of them. Level only changes the animated parts.
        if (rebuildQueued) return;
        rebuildQueued = true;
        window.Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
        {
            rebuildQueued = false;
            Rebuild();
        });
    }

    private static TextBlock Line(string text, double size = 14, double opacity = 1, FontWeight? weight = null, int maxLines = 0, Brush? brush = null) => new()
    {
        Text = text, FontSize = size, FontWeight = weight ?? FontWeights.Medium, Foreground = brush ?? new SolidColorBrush(Color.FromArgb((byte)(opacity * 255), 255, 255, 255)),
        TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis, MaxHeight = maxLines > 0 ? maxLines * size * 1.4 : double.PositiveInfinity,
    };

    private static string TailOf(string text, int characters) => text.Length <= characters ? text : "…" + text[^characters..];

    private void Rebuild()
    {
        if (rebuilding) return;
        rebuilding = true;
        try
        {
            model.HotkeyName = settings.Data.Hotkey.Title();
            root.Visibility = IsVisible ? Visibility.Visible : Visibility.Hidden;
            var width = model.IsOpen ? 500 : model.Phase switch
            {
                IslandPhase.Resting => model.IsRecordingMeeting ? 166 : 118,
                IslandPhase.Thinking => 320,
                IslandPhase.Listening => 380,
                _ => 440,
            };
            var bottom = model.IsOpen ? 28.0 : model.Phase == IslandPhase.Resting ? 10.0 : 22.0;
            shell.Width = width;
            shell.CornerRadius = new CornerRadius(0, 0, bottom, bottom);
            shell.BorderThickness = new Thickness(1, 0, 1, 1);
            shell.BorderBrush = new SolidColorBrush(Color.FromArgb((byte)(model.Phase != IslandPhase.Resting || model.IsOpen ? 23 : 0), 255, 255, 255));
            spark = null;
            bars = null;
            dots = null;
            shell.Child = model.IsOpen ? BuildHome() : BuildCompact();
            glow.Visibility = !model.IsOpen && model.Phase is IslandPhase.Listening or IslandPhase.Speaking ? Visibility.Visible : Visibility.Collapsed;
            glow.Width = width - 12;
            glow.CornerRadius = shell.CornerRadius;
        }
        finally { rebuilding = false; }
    }

    private UIElement BuildCompact()
    {
        var stack = new StackPanel();
        var header = new DockPanel { Height = model.Phase == IslandPhase.Resting ? 26 : 38, Margin = new Thickness(model.Phase == IslandPhase.Resting ? 0 : 18, 0, model.Phase == IslandPhase.Resting ? 0 : 18, 0), LastChildFill = false };
        if (model.Phase == IslandPhase.Resting)
        {
            if (model.IsRecordingMeeting)
            {
                var dot = new Ellipse { Width = 9, Height = 9, Fill = Brushes.Red, Margin = new Thickness(0, 0, 14, 0), VerticalAlignment = VerticalAlignment.Center, ToolTip = "Taking meeting notes" };
                DockPanel.SetDock(dot, Dock.Right);
                header.Children.Add(dot);
            }
            else
            {
                var mark = JarvisStyle.SparkMark(13);
                mark.HorizontalAlignment = HorizontalAlignment.Center;
                var center = new Grid { Width = shell.Width - 2 };
                center.Children.Add(mark);
                header.Children.Add(center);
            }
        }
        else
        {
            spark = JarvisStyle.SparkMark(18);
            spark.RenderTransformOrigin = new Point(0.5, 0.5);
            spark.VerticalAlignment = VerticalAlignment.Center;
            header.Children.Add(spark);
            if (TrailingIndicator() is { } trailing)
            {
                DockPanel.SetDock(trailing, Dock.Right);
                trailing.VerticalAlignment = VerticalAlignment.Center;
                header.Children.Add(trailing);
            }
        }
        stack.Children.Add(header);
        if (PhaseBody() is { } body) stack.Children.Add(body);
        return stack;
    }

    private FrameworkElement? TrailingIndicator()
    {
        switch (model.Phase)
        {
            case IslandPhase.Listening:
            case IslandPhase.Speaking:
                bars = new StackPanel { Orientation = Orientation.Horizontal, Height = 20 };
                for (var i = 0; i < 5; i++) bars.Children.Add(new Border { Width = 3, Height = 4, CornerRadius = new CornerRadius(1.5), Background = JarvisStyle.Brand, Margin = new Thickness(1.5, 0, 1.5, 0), VerticalAlignment = VerticalAlignment.Center });
                return bars;
            case IslandPhase.Thinking:
                dots = new StackPanel { Orientation = Orientation.Horizontal };
                for (var i = 0; i < 3; i++) dots.Children.Add(new Ellipse { Width = 5, Height = 5, Fill = Brushes.White, Margin = new Thickness(2, 0, 2, 0) });
                return dots;
            case IslandPhase.Guiding:
                return new Border
                {
                    Background = JarvisStyle.Brand, CornerRadius = new CornerRadius(10), Padding = new Thickness(9, 3, 9, 3),
                    Child = new TextBlock { Text = $"Step {model.GuideStep}", FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White },
                };
            case IslandPhase.Confirming:
                return new TextBlock { Text = "", FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 14, Foreground = JarvisStyle.AmberBrush };
            case IslandPhase.Message:
                return new TextBlock { Text = "", FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 14, Foreground = JarvisStyle.AmberBrush };
            case IslandPhase.Offering:
                return new TextBlock { Text = "", FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 14, Foreground = JarvisStyle.AmberBrush };
            default:
                return null;
        }
    }

    private static readonly Thickness BodyMargin = new(18, 0, 18, 14);

    private UIElement? PhaseBody()
    {
        switch (model.Phase)
        {
            case IslandPhase.Listening:
                return BodyText(model.Transcript.Length == 0 ? "Listening…" : TailOf(model.Transcript, 220), model.Transcript.Length == 0);
            case IslandPhase.Thinking:
                return BodyText(model.Progress.Length == 0 ? "Looking at your screen…" : model.Progress, true);
            case IslandPhase.Speaking:
            {
                var panel = new StackPanel { Margin = BodyMargin };
                if (model.Activity.Length > 0) panel.Children.Add(new TextBlock { Text = model.Activity, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = new SolidColorBrush(Color.FromArgb(178, 255, 255, 255)), Margin = new Thickness(0, 0, 0, 6), TextTrimming = TextTrimming.CharacterEllipsis });
                panel.Children.Add(ReplyWithStop());
                AddNotice(panel);
                return panel;
            }
            case IslandPhase.Guiding:
            {
                var panel = new StackPanel { Margin = BodyMargin };
                panel.Children.Add(ReplyWithStop());
                panel.Children.Add(new TextBlock { Text = "Click the circled spot to continue, or press Esc to stop.", FontSize = 11, Foreground = new SolidColorBrush(Color.FromArgb(140, 255, 255, 255)), Margin = new Thickness(0, 6, 0, 0), TextWrapping = TextWrapping.Wrap });
                AddNotice(panel);
                return panel;
            }
            case IslandPhase.Confirming:
                return Confirmation();
            case IslandPhase.Message:
                return BodyText(model.Message, false);
            case IslandPhase.Offering:
                return Offer();
            default:
                return null;
        }
    }

    private UIElement BodyText(string text, bool dim)
    {
        var line = Line(text, 14, dim ? 0.6 : 1, maxLines: 4);
        line.Margin = BodyMargin;
        return line;
    }

    private void AddNotice(StackPanel panel)
    {
        if (model.Notice.Length == 0) return;
        panel.Children.Add(new TextBlock { Text = model.Notice, FontSize = 11, Foreground = JarvisStyle.AmberBrush, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0), MaxHeight = 32 });
    }

    private UIElement ReplyWithStop()
    {
        var row = new DockPanel();
        var stop = JarvisStyle.Plain(new TextBlock { Text = "", FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 15, Foreground = new SolidColorBrush(Color.FromArgb(102, 255, 255, 255)), Margin = new Thickness(10, 2, 0, 0) }, () => model.OnStop(), "Stop (Esc)");
        DockPanel.SetDock(stop, Dock.Right);
        stop.VerticalAlignment = VerticalAlignment.Top;
        row.Children.Add(stop);
        row.Children.Add(Line(TailOf(model.Reply, 340), 14, 1, maxLines: 5));
        return row;
    }

    private UIElement Offer()
    {
        var panel = new StackPanel { Margin = BodyMargin };
        panel.Children.Add(Line($"{model.OfferTitle}. Want me to take a look?", 14, 1, FontWeights.SemiBold));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 0) };
        buttons.Children.Add(JarvisStyle.Pill("Take a look", true, () => model.OnAcceptOffer()));
        var no = JarvisStyle.Pill("Not now", false, () => model.OnDismissOffer());
        no.Margin = new Thickness(8, 0, 0, 0);
        buttons.Children.Add(no);
        panel.Children.Add(buttons);
        return panel;
    }

    private UIElement Confirmation()
    {
        var panel = new StackPanel { Margin = BodyMargin };
        panel.Children.Add(Line(model.ConfirmTitle, 14, 1, FontWeights.SemiBold));
        if (model.ConfirmDetail.Length > 0)
        {
            var detail = Line(model.ConfirmDetail, 12, 0.7, FontWeights.Normal, maxLines: 4);
            detail.Margin = new Thickness(0, 6, 0, 0);
            panel.Children.Add(detail);
        }
        AddNotice(panel);
        var buttons = new DockPanel { Margin = new Thickness(0, 10, 0, 0), LastChildFill = false };
        var yes = JarvisStyle.Pill("Yes, do it", true, () => model.OnConfirm(true));
        var no = JarvisStyle.Pill("No", false, () => model.OnConfirm(false));
        no.Margin = new Thickness(8, 0, 0, 0);
        buttons.Children.Add(yes);
        buttons.Children.Add(no);
        var hint = new TextBlock { Text = $"Or hold {model.HotkeyName} and say yes or no", FontSize = 11, Foreground = new SolidColorBrush(Color.FromArgb(140, 255, 255, 255)), VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(hint, Dock.Right);
        buttons.Children.Add(hint);
        panel.Children.Add(buttons);
        return panel;
    }

    /// <summary>Opens when you hover over the island: your conversation and a box to type a question.</summary>
    private UIElement BuildHome()
    {
        var panel = new StackPanel { Margin = new Thickness(18, 16, 18, 16) };
        var top = new DockPanel { LastChildFill = false, Margin = new Thickness(0, 0, 0, 12) };
        top.Children.Add(JarvisStyle.SparkMark(18));
        top.Children.Add(new TextBlock { Text = "Jarvis", FontSize = 15, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, Margin = new Thickness(9, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
        var gear = JarvisStyle.Plain(new TextBlock { Text = "", FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 13, Foreground = new SolidColorBrush(Color.FromArgb(140, 255, 255, 255)), Margin = new Thickness(9, 0, 0, 0) }, () => model.OnOpenSettings(), "Settings");
        DockPanel.SetDock(gear, Dock.Right);
        top.Children.Add(gear);
        var hold = new TextBlock { Text = $"Hold {model.HotkeyName} to talk", FontSize = 11, FontWeight = FontWeights.Medium, Foreground = new SolidColorBrush(Color.FromArgb(128, 255, 255, 255)), VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(hold, Dock.Right);
        top.Children.Add(hold);
        panel.Children.Add(top);

        if (model.Conversation.Count == 0)
        {
            panel.Children.Add(new TextBlock { Text = "What can I help with?", FontSize = 21, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, Margin = new Thickness(0, 6, 0, 10) });
            var chips = new WrapPanel { Margin = new Thickness(0, 0, 0, 12) };
            foreach (var suggestion in Suggestions)
            {
                var chip = new Border { Background = new SolidColorBrush(Color.FromArgb(26, 255, 255, 255)), CornerRadius = new CornerRadius(13), Padding = new Thickness(10, 6, 10, 6), Child = new TextBlock { Text = suggestion, FontSize = 11, FontWeight = FontWeights.Medium, Foreground = new SolidColorBrush(Color.FromArgb(217, 255, 255, 255)) } };
                var button = JarvisStyle.Plain(chip, () => Send(suggestion));
                button.Margin = new Thickness(0, 0, 7, 4);
                chips.Children.Add(button);
            }
            panel.Children.Add(chips);
        }
        else panel.Children.Add(ConversationList());
        panel.Children.Add(Composer());
        return panel;
    }

    private UIElement ConversationList()
    {
        var list = new StackPanel();
        foreach (var turn in model.Conversation)
        {
            if (!turn.User.StartsWith("(clicked", StringComparison.Ordinal))
            {
                list.Children.Add(new Border
                {
                    Background = new SolidColorBrush(Color.FromArgb(33, 255, 255, 255)), CornerRadius = new CornerRadius(14), Padding = new Thickness(11, 7, 11, 7),
                    HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(40, 0, 0, 10),
                    Child = new TextBlock { Text = turn.User, FontSize = 13, FontWeight = FontWeights.Medium, Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap },
                });
            }
            list.Children.Add(new TextBox
            {
                Text = turn.Assistant, FontSize = 13, IsReadOnly = true, BorderThickness = new Thickness(0), Background = Brushes.Transparent,
                Foreground = new SolidColorBrush(Color.FromArgb(224, 255, 255, 255)), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 10), CaretBrush = Brushes.Transparent,
            });
        }
        var scroll = new ScrollViewer { Content = list, MaxHeight = 230, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, Margin = new Thickness(0, 0, 0, 12) };
        scroll.Loaded += (_, _) => scroll.ScrollToEnd();
        return scroll;
    }

    private UIElement Composer()
    {
        var hint = new TextBlock { Text = "Ask about your screen…", FontSize = 13, Foreground = new SolidColorBrush(Color.FromArgb(115, 255, 255, 255)), IsHitTestVisible = false, VerticalAlignment = VerticalAlignment.Center, Visibility = draft.Length == 0 ? Visibility.Visible : Visibility.Collapsed };
        var box = composer = new TextBox { Text = draft, FontSize = 13, BorderThickness = new Thickness(0), Background = Brushes.Transparent, Foreground = Brushes.White, CaretBrush = Brushes.White, VerticalContentAlignment = VerticalAlignment.Center };
        box.CaretIndex = draft.Length;
        box.TextChanged += (_, _) =>
        {
            draft = box.Text;
            hint.Visibility = draft.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        };
        box.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter) Send(draft);
        };
        // Taking the keyboard is the one thing the island asks of Windows, and only because they clicked into the box.
        box.PreviewMouseLeftButtonDown += (_, _) => TakeKeyboard();
        var field = new Grid { Margin = new Thickness(0, 0, 6, 0) };
        field.Children.Add(hint);
        field.Children.Add(box);
        var send = JarvisStyle.Plain(new TextBlock { Text = "", FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 17, Foreground = JarvisStyle.Brand }, () => Send(draft));
        DockPanel.SetDock(send, Dock.Right);
        var row = new DockPanel();
        row.Children.Add(send);
        row.Children.Add(field);
        return new Border { Background = new SolidColorBrush(Color.FromArgb(26, 255, 255, 255)), CornerRadius = new CornerRadius(17), Padding = new Thickness(13, 6, 8, 6), Child = row };
    }

    private void TakeKeyboard()
    {
        if (Win32.GetForegroundWindow() == handle) return;
        focusBefore = Win32.GetForegroundWindow();
        Win32.SetActivatable(handle, true);
        Win32.SetForegroundWindow(handle);
    }

    /// <summary>Hands the keyboard back to whichever app they were using, so a request goes on to see that app.</summary>
    private void ReleaseKeyboard()
    {
        Win32.SetActivatable(handle, false);
        if (focusBefore != IntPtr.Zero && Win32.GetForegroundWindow() == handle) Win32.SetForegroundWindow(focusBefore);
        focusBefore = IntPtr.Zero;
    }

    private void Send(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return;
        draft = "";
        ReleaseKeyboard();
        model.OnAsk(trimmed);
    }

    private void Tick()
    {
        if (handle == IntPtr.Zero || current is null) return;
        var (mouseX, mouseY) = Win32.CursorPosition();

        // The island follows you between displays, but never moves while it's in use.
        if (model.Phase == IslandPhase.Resting && !model.IsOpen && !current.Contains(mouseX, mouseY))
        {
            var next = ScreenCapture.Displays().FirstOrDefault(d => d.Contains(mouseX, mouseY));
            if (next is not null)
            {
                Place(next);
                return;
            }
        }

        var scale = VisualTreeHelper.GetDpi(window).DpiScaleX;
        double shellWidth = shell.ActualWidth * scale, shellHeight = shell.ActualHeight * scale;
        var left = current.X + (current.Width - shellWidth) / 2;
        var isOver = IsVisible && mouseX >= left && mouseX <= left + shellWidth && mouseY >= current.Y && mouseY <= current.Y + shellHeight;
        Win32.SetClickThrough(handle, !isOver);
        UpdateHover(isOver);

        if (wasOpen && !model.IsOpen) ReleaseKeyboard();
        wasOpen = model.IsOpen;
    }

    private void UpdateHover(bool isOver)
    {
        var now = DateTime.UtcNow;
        if (isOver)
        {
            leftAt = null;
            if (model.IsOpen || model.Phase != IslandPhase.Resting) return;
            hoverStarted ??= now;
            if (now - hoverStarted >= HoverOpenDelay)
            {
                model.IsOpen = true;
                hoverStarted = null;
            }
        }
        else
        {
            hoverStarted = null;
            if (!model.IsOpen) return;
            leftAt ??= now;
            if (now - leftAt >= HoverCloseDelay)
            {
                model.IsOpen = false;
                leftAt = null;
            }
        }
    }

    private static readonly double[] BarWeights = { 0.55, 0.85, 1, 0.7, 0.45 };

    /// <summary>The spark, the voice bars and the dots move on their own clock, so they don't redraw the island.</summary>
    private void Animate()
    {
        var time = DateTime.UtcNow.TimeOfDay.TotalSeconds;
        var level = (double)model.Level;
        if (spark is not null)
        {
            var size = model.Phase switch
            {
                IslandPhase.Listening => 1 + level * 0.45,
                IslandPhase.Speaking => 1 + 0.08 * Math.Sin(time * 5),
                _ => 1 + 0.04 * Math.Sin(time * 1.6),
            };
            var group = new TransformGroup();
            group.Children.Add(new ScaleTransform(size, size));
            if (model.Phase == IslandPhase.Thinking) group.Children.Add(new RotateTransform(time * 2.6 * 180 / Math.PI));
            spark.RenderTransform = group;
        }
        if (bars is not null)
        {
            for (var i = 0; i < bars.Children.Count; i++)
            {
                var wobble = 0.5 + 0.5 * Math.Sin(time * 9 + i * 1.3);
                var amount = model.Phase == IslandPhase.Listening ? 0.12 + level * (0.5 + 0.5 * wobble) : 0.3 + 0.7 * wobble;
                ((Border)bars.Children[i]).Height = Math.Max(4, 20 * BarWeights[i] * Math.Min(amount, 1));
            }
        }
        if (dots is not null)
        {
            for (var i = 0; i < dots.Children.Count; i++)
                dots.Children[i].Opacity = 0.3 + 0.7 * (0.5 + 0.5 * Math.Sin(time * 5 - i * 0.9));
        }
        if (glow.Visibility == Visibility.Visible)
        {
            glow.Height = shell.ActualHeight;
            glow.Opacity = model.Phase == IslandPhase.Listening ? 0.35 + level * 0.55 : 0.4;
        }
    }
}
