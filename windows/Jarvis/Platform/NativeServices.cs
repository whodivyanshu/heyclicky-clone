using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace Jarvis;

/// <summary>
/// Calendar, tasks and contacts through classic Outlook, and mail through the default mail app. Windows has no shared
/// calendar store that a normal desktop app can reach, so these need classic Outlook. The new Outlook has no way in.
/// Shortcuts are Apple's alone, so there's nothing to run here.
/// </summary>
public static class NativeServices
{
    private const int MaxListed = 40, MaxPeople = 5;
    private const int FolderCalendar = 9, FolderContacts = 10, FolderTasks = 13;
    private const int ItemAppointment = 1, ItemTask = 3;

    private static readonly ActionResult NoOutlook = new(
        "Needs classic Outlook",
        "Calendar, tasks and contacts need classic Outlook on Windows, and I couldn't open it on this PC.");

    public static bool HasOutlook => Type.GetTypeFromProgID("Outlook.Application") is not null;

    public static async Task<ActionResult> Run(ActionTag tag) => tag.Kind switch
    {
        "EVENTS" => await Outlook(a => ReadEvents(a, tag.Value)),
        "REMINDERS" => await Outlook(ReadTasks),
        "CONTACT" => await Outlook(a => LookUpContact(a, tag.Value)),
        "ADD_EVENT" => await AddEvent(tag.Value),
        "ADD_REMINDER" => await AddReminder(tag.Value),
        "DRAFT_MAIL" => DraftMail(tag.Value),
        "SHORTCUT" => new ActionResult($"Couldn't run {tag.Value}", "Windows doesn't have Shortcuts, so I can't run that here."),
        _ => new ActionResult(""),
    };

    /// <summary>Outlook's automation has to run on a single-threaded apartment, and can be slow to start, so it gets its own thread.</summary>
    private static Task<ActionResult> Outlook(Func<dynamic, ActionResult> work)
    {
        var done = new TaskCompletionSource<ActionResult>();
        var thread = new Thread(() =>
        {
            try
            {
                var type = Type.GetTypeFromProgID("Outlook.Application");
                if (type is null)
                {
                    done.SetResult(NoOutlook);
                    return;
                }
                dynamic outlook = Activator.CreateInstance(type)!;
                done.SetResult(work(outlook));
            }
            catch (Exception problem) when (problem is COMException or InvalidCastException or Microsoft.CSharp.RuntimeBinder.RuntimeBinderException or System.Reflection.TargetInvocationException)
            {
                Log.Write($"Outlook failed: {problem.GetType().Name}");
                done.SetResult(NoOutlook);
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
        return done.Task;
    }

    private static ActionResult ReadEvents(dynamic outlook, string text)
    {
        if (Core.ParseRange(text) is not { } range)
            return new ActionResult("Couldn't read that date", "I couldn't work out which day you meant.");
        dynamic items = outlook.GetNamespace("MAPI").GetDefaultFolder(FolderCalendar).Items;
        items.IncludeRecurrences = true;
        items.Sort("[Start]");
        // Outlook's filter takes this exact local format.
        var filter = $"[Start] < '{range.End:g}' AND [End] > '{range.Start:g}'";
        var lines = new List<string>();
        foreach (dynamic item in items.Restrict(filter))
        {
            if (lines.Count >= MaxListed) break;
            DateTime start = item.Start, end = item.End;
            bool allDay = item.AllDayEvent;
            string subject = item.Subject ?? "Untitled";
            string place = item.Location ?? "";
            var when = allDay ? $"{start:ddd d MMM}, all day" : $"{start:ddd d MMM}, {start:t} to {end:t}";
            lines.Add($"- {when}: {subject}{(place.Length > 0 ? " at " + place : "")}");
        }
        return new ActionResult("Checked your calendar", Data: lines.Count == 0 ? $"No events {text}." : $"Events {text}:\n" + string.Join("\n", lines));
    }

    private static ActionResult ReadTasks(dynamic outlook)
    {
        dynamic items = outlook.GetNamespace("MAPI").GetDefaultFolder(FolderTasks).Items;
        var lines = new List<string>();
        foreach (dynamic item in items.Restrict("[Complete] = False"))
        {
            if (lines.Count >= MaxListed) break;
            string subject = item.Subject ?? "Untitled";
            DateTime due = item.DueDate;
            // Outlook uses year 4501 for "no date".
            lines.Add($"- {subject}{(due.Year < 4000 ? $", due {due:ddd d MMM}" : "")}");
        }
        return new ActionResult("Checked your tasks", Data: lines.Count == 0 ? "No unfinished reminders." : "Unfinished reminders:\n" + string.Join("\n", lines));
    }

    private static ActionResult LookUpContact(dynamic outlook, string name)
    {
        dynamic items = outlook.GetNamespace("MAPI").GetDefaultFolder(FolderContacts).Items;
        var words = name.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var lines = new List<string>();
        foreach (dynamic item in items)
        {
            if (lines.Count >= MaxPeople) break;
            // A folder can hold contact groups, which don't have these.
            if ((int)item.Class != 40) continue;
            string fullName = item.FullName ?? "";
            string company = item.CompanyName ?? "";
            if (words.Length == 0 || !words.All(w => (fullName + " " + company).ToLowerInvariant().Contains(w))) continue;
            var emails = new[] { (string?)item.Email1Address, (string?)item.Email2Address }.Where(e => !string.IsNullOrEmpty(e));
            var phones = new[] { (string?)item.MobileTelephoneNumber, (string?)item.BusinessTelephoneNumber, (string?)item.HomeTelephoneNumber }.Where(e => !string.IsNullOrEmpty(e));
            lines.Add($"- {(fullName.Length > 0 ? fullName : company)}, email: {string.Join(", ", emails)}; phone: {string.Join(", ", phones)}");
        }
        return new ActionResult("Checked your contacts", Data: lines.Count == 0 ? $"No contact matches {name}." : $"Contacts matching {name}:\n" + string.Join("\n", lines));
    }

    private static Task<ActionResult> AddEvent(string text)
    {
        if (Core.ParseEvent(text) is not { } added)
            return Task.FromResult(new ActionResult("Didn't add the event", "I couldn't work out the title and time for that event."));
        return Outlook(outlook =>
        {
            dynamic item = outlook.CreateItem(ItemAppointment);
            item.Subject = added.Title;
            item.Start = added.Start;
            item.Duration = added.Minutes;
            item.Save();
            return new ActionResult($"Added \"{added.Title}\" to your calendar");
        });
    }

    public static Task<ActionResult> AddReminder(string text)
    {
        if (Core.ParseReminder(text) is not { } added)
            return Task.FromResult(new ActionResult("Didn't add the task", "I couldn't work out when that task is for."));
        return Outlook(outlook =>
        {
            dynamic item = outlook.CreateItem(ItemTask);
            item.Subject = added.Title;
            if (added.Due is { } due)
            {
                item.DueDate = due.Date;
                item.ReminderSet = true;
                item.ReminderTime = due;
            }
            item.Save();
            return new ActionResult($"Added the task \"{added.Title}\"");
        });
    }

    /// <summary>Opens a draft in their mail app, with Jarvis taking no part in sending it.</summary>
    private static ActionResult DraftMail(string text)
    {
        if (Core.MailUrl(text) is not { } url)
            return new ActionResult("Didn't start the email", "I couldn't work out who that email is for.");
        try
        {
            using var process = Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
            return new ActionResult("Opened a draft");
        }
        catch (Exception problem) when (problem is Win32Exception or InvalidOperationException)
        {
            return new ActionResult("Didn't start the email", "I couldn't open your mail app.");
        }
    }
}
