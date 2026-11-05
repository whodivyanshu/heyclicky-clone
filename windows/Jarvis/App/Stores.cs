using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;

namespace Jarvis;

/// <summary>Facts they asked Jarvis to keep. The rules for what's kept are in the core.</summary>
public sealed class MemoryStore
{
    private const string FileName = "memory.json";
    public List<string> Facts { get; private set; }
    public event Action? Changed;

    public MemoryStore() => Facts = JarvisFiles.Load<List<string>>(FileName) ?? new();

    public string? Add(string text)
    {
        var (facts, saved) = Core.MemoryAdd(Facts, text);
        Set(facts);
        return saved;
    }

    public List<string> Forget(string query)
    {
        var (facts, removed) = Core.MemoryForget(Facts, query);
        Set(facts);
        return removed;
    }

    public void Remove(string fact) => Set(Facts.Where(f => f != fact).ToList());
    public void Clear() => Set(new());

    private void Set(List<string> facts)
    {
        Facts = facts;
        JarvisFiles.Save(Facts, FileName);
        Changed?.Invoke();
    }
}

public sealed class ConversationEntry
{
    public Guid Id { get; set; }
    public DateTime Date { get; set; }
    public string User { get; set; } = "";
    public string Assistant { get; set; } = "";
}

public sealed class ConversationStore
{
    public const int MaxEntries = 1000;
    private const string FileName = "conversations.json";
    private CancellationTokenSource? pendingSave;
    public List<ConversationEntry> Entries { get; }

    public ConversationStore() => Entries = JarvisFiles.Load<List<ConversationEntry>>(FileName) ?? new();

    /// <summary>A long job updates its reply at every step, so this waits for a quiet moment before writing.</summary>
    public void Save(ConversationEntry entry)
    {
        var index = Entries.FindLastIndex(e => e.Id == entry.Id);
        if (index >= 0) Entries[index] = entry;
        else
        {
            Entries.Add(entry);
            if (Entries.Count > MaxEntries) Entries.RemoveRange(0, Entries.Count - MaxEntries);
        }
        pendingSave?.Cancel();
        var cancel = pendingSave = new CancellationTokenSource();
        _ = Task.Delay(500, cancel.Token).ContinueWith(t =>
        {
            if (!t.IsCanceled) JarvisFiles.Save(Entries, FileName);
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    /// <summary>Newest first. Every word has to appear in what they said or in the reply.</summary>
    public IEnumerable<ConversationEntry> Search(string query)
    {
        var words = query.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        return Enumerable.Reverse(Entries).Where(entry =>
        {
            var text = (entry.User + " " + entry.Assistant).ToLowerInvariant();
            return words.All(text.Contains);
        });
    }

    public void Remove(Guid id)
    {
        Entries.RemoveAll(e => e.Id == id);
        JarvisFiles.Save(Entries, FileName);
    }

    public void Clear()
    {
        pendingSave?.Cancel();
        Entries.Clear();
        JarvisFiles.Save(Entries, FileName);
    }
}

public sealed class ActivityEntry
{
    public Guid Id { get; set; }
    public DateTime Date { get; set; }
    public string Request { get; set; } = "";
    public string Summary { get; set; } = "";
    public string? Failure { get; set; }
    public string? Screenshot { get; set; }
}

public sealed class ActivityStore
{
    public const int MaxEntries = 500;
    private const string FileName = "activity.json";
    public List<ActivityEntry> Entries { get; }

    public ActivityStore() => Entries = JarvisFiles.Load<List<ActivityEntry>>(FileName) ?? new();

    public void Add(string request, string summary, string? failure, byte[]? screenshot)
    {
        var id = Guid.NewGuid();
        string? fileName = null;
        if (screenshot is not null)
        {
            fileName = $"{id}.jpg";
            JarvisFiles.WriteAllBytes(Path.Combine(JarvisFiles.Screenshots, fileName), screenshot);
        }
        Entries.Add(new ActivityEntry
        {
            Id = id, Date = DateTime.Now, Request = request.Length > 300 ? request[..300] : request,
            Summary = summary, Failure = failure, Screenshot = fileName,
        });
        if (Entries.Count > MaxEntries)
        {
            var removed = Entries.Take(Entries.Count - MaxEntries).ToList();
            Entries.RemoveRange(0, removed.Count);
            DeleteScreenshots(removed);
        }
        JarvisFiles.Save(Entries, FileName);
    }

    public string? ScreenshotPath(ActivityEntry entry) => entry.Screenshot is null ? null : Path.Combine(JarvisFiles.Screenshots, entry.Screenshot);

    public void Clear()
    {
        DeleteScreenshots(Entries);
        Entries.Clear();
        JarvisFiles.Save(Entries, FileName);
    }

    private void DeleteScreenshots(IEnumerable<ActivityEntry> entries)
    {
        foreach (var entry in entries)
        {
            if (ScreenshotPath(entry) is { } path) { try { File.Delete(path); } catch { } }
        }
    }
}

/// <summary>Routines stay as the core's own JSON, and only the core reads or changes them.</summary>
public sealed class RoutineStore
{
    private static readonly string FilePath = Path.Combine(JarvisFiles.Folder, "routines.json");
    public string Book { get; private set; }

    public RoutineStore()
    {
        try { Book = File.ReadAllText(FilePath); }
        catch { Book = ""; }
        // A damaged file throws here, and is set aside rather than overwritten by the next save.
        try { Core.RoutineList(Book); }
        catch (CoreException)
        {
            Log.Write("Couldn't read the saved routines.");
            try { File.Move(FilePath, FilePath + ".damaged", overwrite: true); } catch { }
            Book = "";
        }
    }

    public void Set(string book)
    {
        Book = book;
        JarvisFiles.WriteAllBytes(FilePath, System.Text.Encoding.UTF8.GetBytes(book));
    }
}

public sealed class MeetingLine
{
    public string Speaker { get; set; } = "";
    public string Text { get; set; } = "";
    public DateTime Date { get; set; }
}

public sealed class MeetingNote
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public DateTime Start { get; set; }
    public DateTime? End { get; set; }
    public List<MeetingLine> Lines { get; set; } = new();
    public string? Summary { get; set; }
    public string? Problem { get; set; }

    public string Transcript => string.Join("\n", Lines.OrderBy(l => l.Date).Select(l => $"{l.Speaker}: {l.Text}"));
}

public sealed class MeetingStore
{
    public const int MaxNotes = 100;
    private const string FileName = "meetings.json";
    public List<MeetingNote> Notes { get; }

    public MeetingStore() => Notes = JarvisFiles.Load<List<MeetingNote>>(FileName) ?? new();

    public void Save(MeetingNote note)
    {
        var index = Notes.FindIndex(n => n.Id == note.Id);
        if (index >= 0) Notes[index] = note;
        else
        {
            Notes.Add(note);
            if (Notes.Count > MaxNotes) Notes.RemoveRange(0, Notes.Count - MaxNotes);
        }
        JarvisFiles.Save(Notes, FileName);
    }

    public void Remove(Guid id)
    {
        Notes.RemoveAll(n => n.Id == id);
        JarvisFiles.Save(Notes, FileName);
    }
}

public sealed record ScreenMemoryHit(DateTime Date, string App, string Snippet);

/// <summary>
/// Text from the screen, in a full-text index, the same as the Mac app's database. Images are never kept.
/// What goes in, and how a search is quoted, are decided by the core. The file isn't created until this is turned on.
/// </summary>
public sealed class ScreenMemoryStore
{
    private static readonly string FilePath = Path.Combine(JarvisFiles.Folder, "screen-memory.sqlite");
    private readonly object gate = new();
    private SqliteConnection? connection;
    private string? lastSaved;
    private DateTime lastPurge = DateTime.MinValue;

    private static bool FileExists => File.Exists(FilePath);

    private SqliteConnection Open()
    {
        if (connection is not null) return connection;
        Directory.CreateDirectory(JarvisFiles.Folder);
        var opened = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = FilePath, Pooling = false }.ToString());
        opened.Open();
        using var create = opened.CreateCommand();
        create.CommandText = "CREATE VIRTUAL TABLE IF NOT EXISTS screens USING fts5(body, app UNINDEXED, date UNINDEXED);";
        create.ExecuteNonQuery();
        return connection = opened;
    }

    private void Run(string sql, params (string Name, object Value)[] values)
    {
        lock (gate)
        {
            using var command = Open().CreateCommand();
            command.CommandText = sql;
            foreach (var (name, value) in values) command.Parameters.AddWithValue(name, value);
            command.ExecuteNonQuery();
        }
    }

    public int Count
    {
        get
        {
            if (!FileExists) return 0;
            try
            {
                lock (gate)
                {
                    using var command = Open().CreateCommand();
                    command.CommandText = "SELECT count(*) FROM screens;";
                    return Convert.ToInt32(command.ExecuteScalar());
                }
            }
            catch (SqliteException) { return 0; }
        }
    }

    public void Remember(string text, string app, int keepingDays)
    {
        var clean = Core.Redacted(text);
        if (!Core.IsWorthSaving(clean, lastSaved)) return;
        lastSaved = clean;
        Run("INSERT INTO screens (body, app, date) VALUES ($body, $app, $date);",
            ("$body", clean), ("$app", app), ("$date", DateTimeOffset.Now.ToUnixTimeMilliseconds() / 1000.0));
        if (DateTime.Now - lastPurge > TimeSpan.FromHours(1))
        {
            lastPurge = DateTime.Now;
            Purge(keepingDays);
        }
    }

    public void Purge(int keepingDays)
    {
        if (!FileExists) return;
        var cutoff = DateTimeOffset.Now.AddDays(-keepingDays).ToUnixTimeMilliseconds() / 1000.0;
        Run("DELETE FROM screens WHERE CAST(date AS REAL) < $cutoff;", ("$cutoff", cutoff));
    }

    /// <summary>Newest first. The query is quoted by the core, so nothing typed can act as search syntax.</summary>
    public List<ScreenMemoryHit> Search(string query, int limit = 20)
    {
        var hits = new List<ScreenMemoryHit>();
        if (!FileExists || Core.MatchQuery(query) is not { } match) return hits;
        lock (gate)
        {
            using var command = Open().CreateCommand();
            command.CommandText = "SELECT date, app, snippet(screens, 0, '', '', ' … ', 24) FROM screens WHERE screens MATCH $match ORDER BY CAST(date AS REAL) DESC LIMIT $limit;";
            command.Parameters.AddWithValue("$match", match);
            command.Parameters.AddWithValue("$limit", limit);
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                var date = DateTimeOffset.FromUnixTimeMilliseconds((long)(Convert.ToDouble(reader.GetValue(0)) * 1000)).LocalDateTime;
                hits.Add(new ScreenMemoryHit(date, reader.GetString(1), reader.GetString(2)));
            }
        }
        return hits;
    }

    /// <summary>Deletes everything and shrinks the file, so the text doesn't linger inside it.</summary>
    public void Clear()
    {
        if (!FileExists) return;
        Run("DELETE FROM screens;");
        Run("INSERT INTO screens(screens) VALUES('rebuild');");
        Run("VACUUM;");
        lastSaved = null;
    }
}

/// <summary>Teaching notes they've written themselves. The built-in ones are in the core.</summary>
public static class TeachingFiles
{
    public static List<Core.Pack> Custom()
    {
        try
        {
            return Directory.GetFiles(JarvisFiles.TeachingPacks, "*.md").OrderBy(f => f, StringComparer.OrdinalIgnoreCase)
                .Select(f => Core.ParsePack(Path.GetFileName(f), File.ReadAllText(f).Replace("\r\n", "\n")))
                .Where(p => p is not null).Select(p => p!).ToList();
        }
        catch { return new(); }
    }
}
