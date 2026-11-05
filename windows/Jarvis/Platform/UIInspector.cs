using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace Jarvis;

/// <summary>
/// Reads the front app through UI Automation, the Windows counterpart of the Mac's Accessibility. It only reads.
/// Field contents aren't collected, apart from the selection they've made themselves.
/// Roles are reported in the words the shared safety rules expect, such as "textfield".
/// </summary>
public static class UIInspector
{
    private const double WalkBudgetSeconds = 0.6;
    private const int MaxVisited = 1500, MaxControls = 120;
    /// <summary>A stuck app must not hang Jarvis, so each read has a deadline, and past it counts as not knowing.</summary>
    private const int CallTimeoutMs = 700;

    /// <summary>Runs on a worker thread, because a hung app can block a UI Automation call for a long time.</summary>
    private static T Bounded<T>(Func<T> read, T fallback)
    {
        try
        {
            var work = Task.Run(read);
            return work.Wait(CallTimeoutMs) ? work.Result : fallback;
        }
        catch (AggregateException) { return fallback; }
    }

    private static string Role(AutomationElement element)
    {
        var type = element.Current.ControlType;
        if (type == ControlType.Button || type == ControlType.SplitButton) return "button";
        if (type == ControlType.Hyperlink) return "link";
        if (type == ControlType.Edit) return "textfield";
        if (type == ControlType.Document) return IsEditable(element) ? "textarea" : "document";
        if (type == ControlType.ComboBox) return "combobox";
        if (type == ControlType.CheckBox) return "checkbox";
        if (type == ControlType.RadioButton) return "radio button";
        if (type == ControlType.ListItem || type == ControlType.TreeItem || type == ControlType.DataItem) return "row";
        if (type == ControlType.MenuItem) return "menu item";
        if (type == ControlType.TabItem) return "tab";
        if (type == ControlType.Custom || type == ControlType.Pane || type == ControlType.Group) return "group";
        return type.ProgrammaticName.Replace("ControlType.", "").ToLowerInvariant();
    }

    private static bool IsEditable(AutomationElement element) =>
        element.TryGetCurrentPattern(ValuePattern.Pattern, out var pattern) && !((ValuePattern)pattern).Current.IsReadOnly;

    private static readonly HashSet<ControlType> ControlTypes = new()
    {
        ControlType.Button, ControlType.SplitButton, ControlType.Hyperlink, ControlType.Edit, ControlType.ComboBox, ControlType.CheckBox,
        ControlType.RadioButton, ControlType.ListItem, ControlType.TreeItem, ControlType.DataItem, ControlType.MenuItem, ControlType.TabItem,
    };

    private static List<string> OwnLabels(AutomationElement element)
    {
        var labels = new List<string>();
        var name = element.Current.Name?.Trim();
        if (!string.IsNullOrEmpty(name)) labels.Add(name);
        var help = element.Current.HelpText?.Trim();
        if (!string.IsNullOrEmpty(help)) labels.Add(help);
        return labels;
    }

    private static string? InnerText(AutomationElement element, int depth = 3)
    {
        if (depth <= 0) return null;
        var walker = TreeWalker.ControlViewWalker;
        var child = walker.GetFirstChild(element);
        for (var count = 0; child is not null && count < 8; count++)
        {
            if (child.Current.ControlType == ControlType.Text && !string.IsNullOrWhiteSpace(child.Current.Name)) return child.Current.Name.Trim();
            if (InnerText(child, depth - 1) is { } text) return text;
            child = walker.GetNextSibling(child);
        }
        return null;
    }

    // For the safety checks

    /// <summary>What the control under a point calls itself.</summary>
    public static List<string> LabelsAt(int x, int y) => Bounded(() =>
    {
        var labels = new List<string>();
        try
        {
            var current = AutomationElement.FromPoint(new System.Windows.Point(x, y));
            var walker = TreeWalker.ControlViewWalker;
            for (var level = 0; level < 4 && current is not null; level++)
            {
                var type = current.Current.ControlType;
                if (type == ControlType.Window || type == ControlType.Document) break;
                labels.AddRange(OwnLabels(current));
                if (ControlTypes.Contains(type))
                {
                    if (labels.Count == 0 && InnerText(current) is { } text) labels.Add(text);
                    break;
                }
                current = walker.GetParent(current);
            }
        }
        catch (Exception problem) when (problem is ElementNotAvailableException or InvalidOperationException or System.Runtime.InteropServices.COMException) { }
        return labels;
    }, new List<string>());

    /// <summary>What the keyboard would land on. If it can't be read, the fields stay empty, and the app name still comes from Windows.</summary>
    public static KeyContext CurrentKeyContext()
    {
        var front = ForegroundApp.Current();
        if (front is null) return new KeyContext();
        return Bounded(() =>
        {
            string role = "", label = "", defaultButton = "";
            var surrounding = new List<string>();
            try
            {
                var focused = AutomationElement.FocusedElement;
                if (focused is not null && focused.Current.ProcessId == (int)front.ProcessId)
                {
                    role = focused.Current.IsPassword ? "securetextfield" : Role(focused);
                    label = string.Join(" ", OwnLabels(focused));
                    var walker = TreeWalker.ControlViewWalker;
                    var parent = walker.GetParent(focused);
                    for (var level = 0; level < 6 && parent is not null && parent.Current.ControlType != ControlType.Window; level++)
                    {
                        surrounding.AddRange(OwnLabels(parent));
                        parent = walker.GetParent(parent);
                    }
                    defaultButton = DefaultButton(front.Window) ?? "";
                }
            }
            catch (Exception problem) when (problem is ElementNotAvailableException or InvalidOperationException or System.Runtime.InteropServices.COMException) { }
            return new KeyContext(front.DisplayName, front.Title, role, label, defaultButton, surrounding);
        }, new KeyContext(front.DisplayName, front.Title));
    }

    /// <summary>UI Automation has no default-button property, but dialogs name the "OK"-style one through its AutomationId.</summary>
    private static string? DefaultButton(IntPtr window)
    {
        var root = AutomationElement.FromHandle(window);
        var condition = new AndCondition(
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
            new PropertyCondition(AutomationElement.AutomationIdProperty, "1"));
        return root.FindFirst(TreeScope.Children, condition)?.Current.Name;
    }

    /// <summary>Password fields have no system-wide signal on Windows, so this reads the focused control. A hung app counts as not knowing.</summary>
    public static bool? FocusIsPassword() => Bounded<bool?>(() =>
    {
        try { return AutomationElement.FocusedElement?.Current.IsPassword ?? false; }
        catch (Exception problem) when (problem is ElementNotAvailableException or InvalidOperationException or System.Runtime.InteropServices.COMException) { return null; }
    }, null);

    // For the model

    /// <summary>What they've selected in the front app. Password fields are never read.</summary>
    public static string? SelectedText()
    {
        var front = ForegroundApp.Current();
        if (front is null || front.IsJarvis) return null;
        return Bounded(() =>
        {
            try
            {
                var focused = AutomationElement.FocusedElement;
                if (focused is null || focused.Current.IsPassword || focused.Current.ProcessId != (int)front.ProcessId) return null;
                if (!focused.TryGetCurrentPattern(TextPattern.Pattern, out var pattern)) return null;
                var ranges = ((TextPattern)pattern).GetSelection();
                return Core.LimitedContext(string.Join("\n", ranges.Select(r => r.GetText(MaxSelection))));
            }
            catch (Exception problem) when (problem is ElementNotAvailableException or InvalidOperationException or System.Runtime.InteropServices.COMException) { return null; }
        }, null);
    }

    private const int MaxSelection = 8000;

    public sealed record FoundControl(string Role, string Label, double X, double Y, double Width, double Height);

    /// <summary>Starts reading the labeled controls in the front window, off the UI thread, so it can happen while the screenshot is taken.</summary>
    public static Task<List<FoundControl>> StartFindingControls()
    {
        var front = ForegroundApp.Current();
        if (front is null || front.IsJarvis) return Task.FromResult(new List<FoundControl>());
        return Task.Run(() => Walk(front.Window));
    }

    private static List<FoundControl> Walk(IntPtr window)
    {
        var found = new List<FoundControl>();
        try
        {
            var root = AutomationElement.FromHandle(window);
            var windowBox = root.Current.BoundingRectangle;
            var clock = Stopwatch.StartNew();
            var walker = TreeWalker.ControlViewWalker;
            var stack = new Stack<AutomationElement>();
            stack.Push(root);
            var visited = 0;
            while (stack.Count > 0 && visited < MaxVisited && found.Count < MaxControls && clock.Elapsed.TotalSeconds < WalkBudgetSeconds)
            {
                var current = stack.Pop();
                visited++;
                var isLeafLike = false;
                try
                {
                    var info = current.Current;
                    var box = info.BoundingRectangle;
                    // Scrolled out of view.
                    if (!box.IsEmpty && !box.IntersectsWith(windowBox)) continue;
                    if (ControlTypes.Contains(info.ControlType) && !box.IsEmpty && !info.IsOffscreen && !info.IsPassword)
                    {
                        var label = OwnLabels(current).FirstOrDefault() ?? InnerText(current);
                        if (label is not null)
                        {
                            found.Add(new FoundControl(Role(current), label, box.X, box.Y, box.Width, box.Height));
                            // A labeled row's insides would only repeat it.
                            isLeafLike = info.ControlType != ControlType.Edit && info.ControlType != ControlType.ComboBox;
                        }
                    }
                }
                catch (ElementNotAvailableException) { continue; }
                if (isLeafLike) continue;

                var children = new List<AutomationElement>();
                try
                {
                    var child = walker.GetFirstChild(current);
                    while (child is not null && children.Count < 200)
                    {
                        children.Add(child);
                        child = walker.GetNextSibling(child);
                    }
                }
                catch (ElementNotAvailableException) { }
                // Reversed, so the walk goes in reading order.
                for (var i = children.Count - 1; i >= 0; i--) stack.Push(children[i]);
            }
        }
        catch (Exception problem) when (problem is ElementNotAvailableException or InvalidOperationException or ArgumentException or System.Runtime.InteropServices.COMException)
        {
            Log.Write($"Reading controls failed: {problem.GetType().Name}");
        }
        return found;
    }

    /// <summary>Converts found controls to screenshot pixels, leaving out any that aren't on a captured screen.</summary>
    public static List<ScreenControl> Controls(IEnumerable<FoundControl> found, IReadOnlyList<ScreenMap> screens)
    {
        var result = new List<ScreenControl>();
        foreach (var control in found)
        {
            var centerX = control.X + control.Width / 2;
            var centerY = control.Y + control.Height / 2;
            var screen = screens.FirstOrDefault(s => centerX >= s.X && centerX < s.X + s.Width && centerY >= s.Y && centerY < s.Y + s.Height);
            if (screen is null) continue;
            var scale = screen.ImageWidth / screen.Width;
            var label = Core.CleanLabel(control.Label);
            if (label.Length == 0) continue;
            result.Add(new ScreenControl(control.Role, label, (centerX - screen.X) * scale, (centerY - screen.Y) * scale, control.Width * scale, control.Height * scale, screen.Index));
        }
        return result;
    }
}
