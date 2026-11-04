import CSherpaOnnx
import CryptoKit
import Combine
import Foundation
import JarvisCore

enum KokoroFiles {
    static let folder = JarvisFiles.folder.appendingPathComponent("Kokoro", isDirectory: true)
    static let runtime = folder.appendingPathComponent("runtime", isDirectory: true)
    static let model = folder.appendingPathComponent(KokoroCatalog.modelFolder, isDirectory: true)
    private static let marker = folder.appendingPathComponent("installed")

    /// Written last, so a download that was cut short never counts.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: marker.path)
    }

    static func markInstalled() {
        FileManager.default.createFile(atPath: marker.path, contents: Data())
    }

    static func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Downloads Kokoro only when asked, and refuses anything whose checksum doesn't match.
@MainActor
final class KokoroInstaller: ObservableObject {
    enum State: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    @Published private(set) var state = State.idle
    @Published private(set) var isInstalled = KokoroFiles.isInstalled
    private var task: Task<Void, Never>?

    static var isSupportedMac: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    func install() {
        guard task == nil else { return }
        task = Task {
            defer { task = nil }
            do {
                state = .working("Downloading the voice engine…")
                let runtime = try await Self.fetch(KokoroCatalog.runtime)
                defer { try? FileManager.default.removeItem(at: runtime) }
                state = .working("Downloading the voices, about \(KokoroCatalog.model.megabytes) MB…")
                let model = try await Self.fetch(KokoroCatalog.model)
                defer { try? FileManager.default.removeItem(at: model) }
                state = .working("Unpacking…")
                try await Task.detached {
                    KokoroFiles.remove()
                    try FileManager.default.createDirectory(at: KokoroFiles.runtime, withIntermediateDirectories: true)
                    // Only the libraries. The archive also holds programs Jarvis has no use for.
                    try Self.unpack(runtime, to: KokoroFiles.runtime, arguments: ["--strip-components", "1", "*/lib/*"])
                    try Self.unpack(model, to: KokoroFiles.folder, arguments: [])
                }.value
                KokoroFiles.markInstalled()
                isInstalled = true
                state = .idle
            } catch is CancellationError {
                state = .idle
            } catch {
                KokoroFiles.remove()
                isInstalled = false
                state = .failed(error.localizedDescription)
            }
        }
    }

    func remove() {
        KokoroEngine.shared.unload()
        KokoroFiles.remove()
        isInstalled = false
        state = .idle
    }

    private static func fetch(_ download: KokoroCatalog.Download) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: download.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw JarvisMessage("The download didn't work. Check your connection and try again.")
        }
        let digest = try await Task.detached { try sha256(of: file) }.value
        guard KokoroCatalog.matches(digest, download.sha256) else {
            try? FileManager.default.removeItem(at: file)
            throw JarvisMessage("A downloaded file didn't match its checksum, so it wasn't installed.")
        }
        return file
    }

    private nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func unpack(_ archive: URL, to folder: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", folder.path] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw JarvisMessage("The download couldn't be unpacked.") }
    }
}

/// Runs Kokoro inside Jarvis. The library is loaded the first time this voice speaks, and let go after a quiet spell,
/// because the model takes a few hundred MB of memory.
final class KokoroEngine: @unchecked Sendable {
    static let shared = KokoroEngine()

    private typealias Create = @convention(c) (UnsafePointer<SherpaOnnxOfflineTtsConfig>) -> OpaquePointer?
    private typealias Destroy = @convention(c) (OpaquePointer) -> Void
    private typealias Generate = @convention(c) (
        OpaquePointer, UnsafePointer<CChar>, UnsafePointer<SherpaOnnxGenerationConfig>, UnsafeRawPointer?, UnsafeMutableRawPointer?
    ) -> UnsafePointer<SherpaOnnxGeneratedAudio>?
    private typealias DestroyAudio = @convention(c) (UnsafePointer<SherpaOnnxGeneratedAudio>) -> Void

    private struct Library {
        let create: Create
        let destroy: Destroy
        let generate: Generate
        let destroyAudio: DestroyAudio
    }

    private static let idleLimit: TimeInterval = 5 * 60
    private static let threads: Int32 = 4

    /// One at a time, on its own thread, since the model can't share and takes a moment.
    private let queue = DispatchQueue(label: "local.jarvis.kokoro", qos: .userInitiated)
    private var library: Library?
    private var engine: OpaquePointer?
    private var lastUsed = Date()

    private func loadLibrary() throws -> Library {
        if let library { return library }
        let folder = KokoroFiles.runtime.appendingPathComponent("lib")
        // It finds the ONNX runtime beside itself.
        guard let handle = dlopen(folder.appendingPathComponent("libsherpa-onnx-c-api.dylib").path, RTLD_NOW | RTLD_LOCAL)
        else {
            throw JarvisMessage("Kokoro couldn't load: \(dlerror().map { String(cString: $0) } ?? "unknown error")")
        }
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let found = dlsym(handle, name) else { throw JarvisMessage("Kokoro is missing \(name). Remove it in Settings and install it again.") }
            return unsafeBitCast(found, to: type)
        }
        let loaded = Library(
            create: try symbol("SherpaOnnxCreateOfflineTts", as: Create.self),
            destroy: try symbol("SherpaOnnxDestroyOfflineTts", as: Destroy.self),
            generate: try symbol("SherpaOnnxOfflineTtsGenerateWithConfig", as: Generate.self),
            destroyAudio: try symbol("SherpaOnnxDestroyOfflineTtsGeneratedAudio", as: DestroyAudio.self)
        )
        library = loaded
        return loaded
    }

    private func loadEngine(_ library: Library) throws -> OpaquePointer {
        if let engine { return engine }
        let model = KokoroFiles.model
        func path(_ name: String) -> String { model.appendingPathComponent(name).path }
        let lexicons = path("lexicon-us-en.txt") + "," + path("lexicon-zh.txt")

        return try path("model.int8.onnx").withCString { modelPath in
            try path("voices.bin").withCString { voices in
                try path("tokens.txt").withCString { tokens in
                    try path("espeak-ng-data").withCString { data in
                        try path("dict").withCString { dict in
                            try lexicons.withCString { lexicon in
                                try "cpu".withCString { provider in
                                    var config = SherpaOnnxOfflineTtsConfig()
                                    config.model.kokoro.model = modelPath
                                    config.model.kokoro.voices = voices
                                    config.model.kokoro.tokens = tokens
                                    config.model.kokoro.data_dir = data
                                    config.model.kokoro.dict_dir = dict
                                    config.model.kokoro.lexicon = lexicon
                                    config.model.kokoro.length_scale = 1
                                    config.model.num_threads = Self.threads
                                    config.model.provider = provider
                                    config.max_num_sentences = 1
                                    config.silence_scale = 0.2
                                    guard let created = library.create(&config) else {
                                        throw JarvisMessage("Kokoro couldn't start. Remove it in Settings and install it again.")
                                    }
                                    engine = created
                                    return created
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Makes speech for this text and returns it as 16-bit samples at 24,000 Hz.
    func speak(_ text: String, voice: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard KokoroFiles.isInstalled else { throw JarvisMessage("Kokoro isn't installed yet.") }
                    let library = try loadLibrary()
                    let engine = try loadEngine(library)
                    var config = SherpaOnnxGenerationConfig()
                    config.speed = 1
                    config.sid = Int32(voice)
                    config.silence_scale = 0.2
                    let extra = KokoroCatalog.generationExtra(for: text).flatMap { strdup($0) }
                    defer { free(extra) }
                    config.extra = UnsafePointer(extra)
                    guard let audio = library.generate(engine, text, &config, nil, nil) else {
                        throw JarvisMessage("Kokoro couldn't read that text.")
                    }
                    defer { library.destroyAudio(audio) }
                    let count = Int(audio.pointee.n)
                    guard count > 0, let samples = audio.pointee.samples else {
                        throw JarvisMessage("Kokoro couldn't read that text.")
                    }
                    let pcm = KokoroCatalog.pcm16(from: UnsafeBufferPointer(start: samples, count: count))
                    lastUsed = Date()
                    scheduleIdleUnload()
                    continuation.resume(returning: pcm)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Lets go of the model. The library stays, because it can't be safely unloaded from a running app.
    func unload() {
        queue.async { [self] in
            if let engine, let library { library.destroy(engine) }
            engine = nil
        }
    }

    private func scheduleIdleUnload() {
        queue.asyncAfter(deadline: .now() + Self.idleLimit + 1) { [self] in
            guard Date().timeIntervalSince(lastUsed) >= Self.idleLimit, let engine, let library else { return }
            library.destroy(engine)
            self.engine = nil
        }
    }
}
