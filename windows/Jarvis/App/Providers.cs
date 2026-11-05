using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Runtime.CompilerServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Jarvis;

public interface IAIProvider
{
    IAsyncEnumerable<string> Stream(AIRequest request, CancellationToken cancel);
}

internal static class Http
{
    /// <summary>Timeouts are per request, because a model that's still loading can take minutes.</summary>
    public static readonly HttpClient Client = new() { Timeout = Timeout.InfiniteTimeSpan };

    /// <summary>Lines from a streaming response, stopping if nothing has arrived for `idle`.</summary>
    public static async IAsyncEnumerable<string> Lines(HttpResponseMessage response, TimeSpan idle, [EnumeratorCancellation] CancellationToken cancel)
    {
        using var stream = await response.Content.ReadAsStreamAsync(cancel);
        using var reader = new StreamReader(stream, Encoding.UTF8);
        while (true)
        {
            using var wait = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            wait.CancelAfter(idle);
            string? line;
            try { line = await reader.ReadLineAsync(wait.Token); }
            catch (OperationCanceledException) when (!cancel.IsCancellationRequested)
            {
                throw new JarvisMessage("The reply stopped arriving. Check your connection and try again.");
            }
            if (line is null) yield break;
            yield return line;
        }
    }

    public static async Task<string> Body(HttpResponseMessage response, CancellationToken cancel)
    {
        try { return await response.Content.ReadAsStringAsync(cancel); }
        catch (HttpRequestException) { return ""; }
    }
}

/// <summary>Gemini, with their API key.</summary>
public sealed class GeminiProvider(string apiKey, string model) : IAIProvider
{
    public async IAsyncEnumerable<string> Stream(AIRequest request, [EnumeratorCancellation] CancellationToken cancel)
    {
        var url = $"https://generativelanguage.googleapis.com/v1beta/models/{Uri.EscapeDataString(model)}:streamGenerateContent?alt=sse";
        using var http = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = new StringContent(Core.GeminiBody(request), Encoding.UTF8, "application/json"),
        };
        http.Headers.Add("x-goog-api-key", apiKey);

        using var wait = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        wait.CancelAfter(TimeSpan.FromSeconds(60));
        HttpResponseMessage response;
        try { response = await Http.Client.SendAsync(http, HttpCompletionOption.ResponseHeadersRead, wait.Token); }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested) { throw new JarvisMessage("Gemini didn't respond in time."); }
        catch (HttpRequestException) { throw new JarvisMessage("Couldn't reach Gemini. Check your connection."); }

        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                var body = await Http.Body(response, cancel);
                throw new JarvisMessage("Gemini: " + (Core.GeminiError(body) ?? $"HTTP {(int)response.StatusCode}"));
            }
            await foreach (var line in Http.Lines(response, TimeSpan.FromSeconds(60), cancel))
            {
                string? text;
                try { text = Core.GeminiText(line); }
                catch (CoreException problem) { throw new JarvisMessage(problem.Message); }
                if (text is not null) yield return text;
            }
        }
    }
}

/// <summary>A model on this PC, so screenshots and questions never leave it. The address is fixed to this machine.</summary>
public sealed class OllamaProvider(string model) : IAIProvider
{
    private const string Endpoint = "http://127.0.0.1:11434";

    public async IAsyncEnumerable<string> Stream(AIRequest request, [EnumeratorCancellation] CancellationToken cancel)
    {
        if (model.Length == 0) throw new JarvisMessage("Choose an Ollama model in Settings first.");
        using var http = new HttpRequestMessage(HttpMethod.Post, Endpoint + "/api/chat")
        {
            Content = new StringContent(Core.OllamaBody(request, model), Encoding.UTF8, "application/json"),
        };
        // A model that isn't in memory yet can take a while to load.
        using var wait = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        wait.CancelAfter(TimeSpan.FromSeconds(180));
        HttpResponseMessage response;
        try { response = await Http.Client.SendAsync(http, HttpCompletionOption.ResponseHeadersRead, wait.Token); }
        catch (Exception problem) when (problem is HttpRequestException || (problem is OperationCanceledException && !cancel.IsCancellationRequested))
        {
            throw new JarvisMessage("Couldn't reach Ollama. Check that it's running on this PC.");
        }

        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                var body = await Http.Body(response, cancel);
                throw new JarvisMessage("Ollama: " + (Core.OllamaError(body) ?? $"HTTP {(int)response.StatusCode}"));
            }
            await foreach (var line in Http.Lines(response, TimeSpan.FromSeconds(180), cancel))
            {
                string? text;
                try { text = Core.OllamaText(line); }
                catch (CoreException problem) { throw new JarvisMessage(problem.Message); }
                if (text is not null) yield return text;
            }
        }
    }

    /// <summary>The models installed on this PC, or null if Ollama isn't running.</summary>
    public static async Task<List<string>?> InstalledModels()
    {
        try
        {
            using var wait = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            using var response = await Http.Client.GetAsync(Endpoint + "/api/tags", wait.Token);
            return response.IsSuccessStatusCode ? Core.OllamaModels(await response.Content.ReadAsStringAsync(wait.Token)) : null;
        }
        catch (Exception problem) when (problem is HttpRequestException or OperationCanceledException) { return null; }
    }
}

/// <summary>Runs the installed claude command, which handles its own login. Jarvis never reads Claude's credentials.</summary>
public sealed class ClaudeCodeProvider(string model) : IAIProvider
{
    public async IAsyncEnumerable<string> Stream(AIRequest request, [EnumeratorCancellation] CancellationToken cancel)
    {
        var found = FindExecutable() ?? throw new JarvisMessage("Couldn't find the claude command. Install Claude Code, or switch to Gemini in Settings.");
        var folder = Path.Combine(Path.GetTempPath(), "jarvis-claude");
        Directory.CreateDirectory(folder);

        var start = new ProcessStartInfo
        {
            WorkingDirectory = folder,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8, StandardInputEncoding = new UTF8Encoding(false),
            UseShellExecute = false, CreateNoWindow = true,
        };
        // The arguments are passed as a list, and never through cmd.exe, so nothing in the prompt can be read as a command.
        var (program, script) = found;
        start.FileName = program;
        if (script is not null) start.ArgumentList.Add(script);
        foreach (var argument in Core.ClaudeArguments(model, request.System)) start.ArgumentList.Add(argument);

        using var process = new Process { StartInfo = start };
        try { process.Start(); }
        catch (Win32Exception) { throw new JarvisMessage("The claude command wouldn't start."); }

        using var stop = cancel.Register(() => Kill(process));
        var input = Core.ClaudeInput(request);
        // Written separately so a large screenshot can't deadlock against the output pipe.
        var writer = Task.Run(async () =>
        {
            try
            {
                await process.StandardInput.WriteAsync(input);
                process.StandardInput.Close();
            }
            catch (Exception problem) when (problem is IOException or ObjectDisposedException or InvalidOperationException) { }
        });
        var errorOutput = process.StandardError.ReadToEndAsync();

        var sawText = false;
        try
        {
            while (true)
            {
                string? line;
                try { line = await process.StandardOutput.ReadLineAsync(cancel); }
                catch (OperationCanceledException) { yield break; }
                if (line is null) break;
                switch (Core.ClaudeEventFrom(line))
                {
                    case { Type: "text" } text:
                        sawText = true;
                        yield return text.Text;
                        break;
                    case { Type: "result" } result:
                        if (result.IsError) throw new JarvisMessage("Claude Code: " + (result.Text.Length == 0 ? "the request failed." : result.Text));
                        if (!sawText && result.Text.Length > 0) yield return result.Text;
                        // The reply is complete, and ending the stream stops the command.
                        yield break;
                }
            }
            await process.WaitForExitAsync(CancellationToken.None);
            await writer;
            if (cancel.IsCancellationRequested) yield break;
            if (process.ExitCode != 0)
            {
                var detail = (await errorOutput).Trim();
                throw new JarvisMessage("Claude Code: " + (detail.Length == 0 ? $"exited with code {process.ExitCode}." : detail[..Math.Min(detail.Length, 300)]));
            }
        }
        finally { Kill(process); }
    }

    private static void Kill(Process process)
    {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
        catch (Exception problem) when (problem is InvalidOperationException or Win32Exception or NotSupportedException) { }
    }

    /// <summary>
    /// The native install is a real program. An npm install is a .cmd launcher, which would go through cmd.exe, where
    /// the prompt's text could be read as commands, so that install runs its Node script directly instead.
    /// </summary>
    public static (string Program, string? Script)? FindExecutable()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var folders = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries).Select(f => f.Trim('"')).ToList();
        string? InPath(string name)
        {
            foreach (var folder in folders)
            {
                try
                {
                    var path = Path.Combine(folder, name);
                    if (File.Exists(path)) return path;
                }
                catch (ArgumentException) { }
            }
            return null;
        }

        var native = new[] { Path.Combine(home, ".local", "bin", "claude.exe"), Path.Combine(home, ".claude", "local", "claude.exe") }.FirstOrDefault(File.Exists) ?? InPath("claude.exe");
        if (native is not null) return (native, null);

        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var script = Path.Combine(roaming, "npm", "node_modules", "@anthropic-ai", "claude-code", "cli.js");
        return File.Exists(script) && InPath("node.exe") is { } node ? (node, script) : null;
    }
}
