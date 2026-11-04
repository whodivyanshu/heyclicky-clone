import Foundation
import JarvisCore

protocol AIProvider: Sendable {
    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error>
}

// MARK: - Gemini (your API key)

struct GeminiProvider: AIProvider {
    let apiKey: String
    let model: String

    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: AIRequest, _ continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        var path = CharacterSet.urlPathAllowed
        path.remove("/")
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: path) ?? model
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):streamGenerateContent?alt=sse") else {
            throw AIError("That Gemini model name isn't valid.")
        }
        var http = URLRequest(url: url)
        http.httpMethod = "POST"
        http.timeoutInterval = 60
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        http.httpBody = try GeminiWire.requestBody(request)

        let (bytes, response) = try await URLSession.shared.bytes(for: http)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw AIError("Gemini: " + (GeminiWire.errorMessage(fromBody: body) ?? "HTTP \(status)"))
        }
        for try await line in bytes.lines {
            if let text = try GeminiWire.text(fromSSELine: line) {
                continuation.yield(text)
            }
        }
    }
}

// MARK: - Ollama (runs on this Mac)

/// A model on this Mac, so screenshots and questions never leave it. The address is fixed to this machine.
struct OllamaProvider: AIProvider {
    let model: String

    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.friendly(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: AIRequest, _ continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        guard !model.isEmpty else { throw AIError("Choose an Ollama model in Settings first.") }
        var http = URLRequest(url: URL(string: OllamaWire.endpoint + "/api/chat")!)
        http.httpMethod = "POST"
        // A model that isn't in memory yet can take a while to load.
        http.timeoutInterval = 180
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.httpBody = try OllamaWire.requestBody(request, model: model)

        let (bytes, response) = try await URLSession.shared.bytes(for: http)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw AIError("Ollama: " + (OllamaWire.errorMessage(fromBody: body) ?? "HTTP \(status)"))
        }
        for try await line in bytes.lines {
            if let text = try OllamaWire.text(fromLine: line) { continuation.yield(text) }
        }
    }

    /// The models installed on this Mac, or nil if Ollama isn't running.
    static func installedModels() async -> [String]? {
        var request = URLRequest(url: URL(string: OllamaWire.endpoint + "/api/tags")!)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return OllamaWire.modelNames(fromTags: data)
    }

    private static func friendly(_ error: Error) -> Error {
        if error is AIError || error is CancellationError { return error }
        if (error as? URLError)?.code == .cancelled { return CancellationError() }
        return AIError("Couldn't reach Ollama. Check that it's running on this Mac.")
    }
}

// MARK: - Claude Code (your local login)

/// Runs the installed `claude` CLI, which handles its own login. Jarvis never reads Claude's credentials.
struct ClaudeCodeProvider: AIProvider {
    let model: String

    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            let task = Task.detached {
                do {
                    try await run(process, request, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                if process.isRunning { process.terminate() }
            }
        }
    }

    private func run(_ process: Process, _ request: AIRequest, _ continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        guard let executable = Self.findExecutable() else {
            throw AIError("Couldn't find the claude command. Install Claude Code, or switch to Gemini in Settings.")
        }
        let workingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-claude", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable
        process.arguments = ClaudeCodeWire.arguments(model: model, system: request.system)
        process.currentDirectoryURL = workingDirectory
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // Written separately so a large screenshot can't deadlock against the stdout pipe.
        let input = try ClaudeCodeWire.inputLine(request)
        let writer = Task.detached {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        let errorOutput = Task.detached {
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }

        var sawText = false
        for try await line in stdout.fileHandleForReading.bytes.lines {
            switch ClaudeCodeWire.event(fromLine: line) {
            case .text(let text):
                sawText = true
                continuation.yield(text)
            case .result(let text, let isError):
                if isError {
                    throw AIError("Claude Code: \(text.isEmpty ? "the request failed." : text)")
                }
                if !sawText, !text.isEmpty { continuation.yield(text) }
                // The reply is complete. The CLI takes about 0.8s more to exit, and ending the stream stops it.
                return
            case nil:
                break
            }
        }
        process.waitUntilExit()
        _ = await writer.value
        let stderrText = await errorOutput.value

        if Task.isCancelled { return }
        if process.terminationStatus != 0 {
            let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AIError("Claude Code: \(detail.isEmpty ? "exited with code \(process.terminationStatus)." : String(detail.prefix(300)))")
        }
    }

    /// Apps opened from Finder don't get the shell's PATH, so check the usual places, then ask a login shell.
    static func findExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        if let found = candidates.first(where: FileManager.default.isExecutableFile) {
            return URL(fileURLWithPath: found)
        }
        let shell = Process()
        let output = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        shell.standardOutput = output
        shell.standardError = Pipe()
        guard (try? shell.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}
