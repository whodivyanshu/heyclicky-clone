import Foundation

/// Kokoro, a free voice model that runs on this Mac, so no service can limit how much it speaks.
public enum KokoroCatalog {
    public struct Download: Equatable, Sendable {
        public var url: URL
        public var sha256: String
        public var megabytes: Int
    }

    /// Pinned by checksum, so a changed file is refused rather than run. 1.13.8 is the last version that
    /// can read Hindi by itself. From 2.0 it would need another tool to turn the text into sounds first.
    public static let runtime = Download(
        url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-osx-arm64-shared.tar.bz2")!,
        sha256: "b10e5c7e2c30ea03de9c442655d14860d9edc475c6251d58a8f5f06e913a1d56",
        megabytes: 19
    )
    public static let model = Download(
        url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_0.tar.bz2")!,
        sha256: "72c347230107ef8a31098ec4d468a605244beef5f1ed00db97efa13518800653",
        megabytes: 126
    )
    public static let modelFolder = "kokoro-int8-multi-lang-v1_0"

    public struct Voice: Equatable, Identifiable, Sendable {
        public var name: String
        public var description: String
        /// The speaker's number in this model.
        public var id: Int
    }

    public static let englishVoices = [
        Voice(name: "Heart", description: "American, female", id: 3),
        Voice(name: "Bella", description: "American, female", id: 2),
        Voice(name: "Nova", description: "American, female", id: 7),
        Voice(name: "Michael", description: "American, male", id: 16),
        Voice(name: "Adam", description: "American, male", id: 11),
        Voice(name: "Onyx", description: "American, male", id: 17),
        Voice(name: "Emma", description: "British, female", id: 21),
        Voice(name: "George", description: "British, male", id: 26),
    ]
    public static let hindiVoices = [
        Voice(name: "Omega", description: "Hindi, male", id: 33),
        Voice(name: "Psi", description: "Hindi, male", id: 34),
        Voice(name: "Alpha", description: "Hindi, female", id: 31),
        Voice(name: "Beta", description: "Hindi, female", id: 32),
    ]
    public static let defaultEnglishVoice = 3
    public static let defaultHindiVoice = 33

    /// Any Devanagari means Hindi. App names written in English stay inside the sentence and go along with it.
    public static func isHindi(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }

    public static func voice(for text: String, english: Int, hindi: Int) -> Int {
        isHindi(text) ? hindi : english
    }

    /// Model-specific settings for one request. Empty for English, which uses the model's own word list.
    public static func generationExtra(for text: String) -> String? {
        isHindi(text) ? #"{"lang":"hi"}"# : nil
    }

    /// Whether a file's checksum is the expected one, ignoring letter case.
    public static func matches(_ actual: String, _ expected: String) -> Bool {
        actual.caseInsensitiveCompare(expected) == .orderedSame
    }

    /// 16-bit little-endian samples, the format the audio player takes.
    public static func pcm16(from samples: UnsafeBufferPointer<Float>) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = Int16((max(-1, min(1, sample)) * 32767).rounded())
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
