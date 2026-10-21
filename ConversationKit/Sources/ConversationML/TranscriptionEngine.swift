import ConversationAudio
import ConversationCore
import Foundation

/// Incremental output of a streaming transcription engine.
public enum TranscriptionEvent: Sendable, Equatable {
    /// A provisional hypothesis for `timeRange` that may still change.
    case volatile(text: String, timeRange: TimeRange?)
    /// Text for `timeRange` that will not change again, with per-word timing
    /// when the engine provides it.
    case finalized(text: String, timeRange: TimeRange?, confidence: Double?, words: [TimedWord] = [])
}

/// Whether an engine can run right now on this device.
/// Shared by transcription and diarization engines.
public typealias EngineAvailability = TranscriptionAvailability

public enum TranscriptionAvailability: Sendable, Equatable {
    case available
    /// Supported, but on-device assets must be downloaded first.
    case assetsRequired
    case unsupported(reason: String)
}

public enum TranscriptionError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedLocale(String)
    case assetsUnavailable(String)
    case noCompatibleAudioFormat
    case audioConversionFailed
    case audioFileUnreadable(String)
    case engineFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedLocale(id): "Speech transcription does not support the \(id) language."
        case let .assetsUnavailable(reason): reason
        case .noCompatibleAudioFormat: "The speech engine could not accept this audio format."
        case .audioConversionFailed: "The audio could not be converted for the speech engine."
        case let .audioFileUnreadable(reason): "The audio file could not be read: \(reason)"
        case let .engineFailure(reason): reason
        }
    }
}

/// Streams audio chunks to an on-device recognizer and emits transcript events.
///
/// Implementations must not block the producer of `audio`; they receive a
/// bounded stream and should process chunks as they arrive. The stream of
/// events finishes after the last chunk has been finalized, or throws when the
/// engine fails. A failure must never affect audio capture.
public protocol StreamingTranscriptionEngine: Sendable {
    var descriptor: EngineDescriptor { get }
    func availability() async -> TranscriptionAvailability
    /// Downloads or installs assets when `availability()` is `.assetsRequired`.
    func prepare() async throws
    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptionEvent, any Error>
}

/// One finalized span of text from a whole-file transcription pass.
public struct TranscribedSpan: Sendable, Equatable {
    public var text: String
    /// Position on the audio file's own timeline, when the engine reports it.
    public var timeRange: TimeRange?
    /// Engine transcription confidence in [0, 1], when reported.
    public var confidence: Double?
    public var words: [TimedWord]

    public init(text: String, timeRange: TimeRange?, confidence: Double?, words: [TimedWord] = []) {
        self.text = text
        self.timeRange = timeRange
        self.confidence = confidence
        self.words = words
    }
}

/// Transcribes a complete, saved audio file (as opposed to a live stream).
///
/// Used to re-transcribe recordings and, in Milestone 2, to fill transcripts for
/// recordings whose live transcription was unavailable. Implementations run on
/// device and must leave the source file untouched.
public protocol FileTranscriptionEngine: Sendable {
    var fileDescriptor: EngineDescriptor { get }
    func availability() async -> TranscriptionAvailability
    func prepare() async throws
    /// - Parameter progress: called with the seconds of audio finalized so far.
    func transcribeFile(
        at url: URL,
        progress: @escaping @Sendable (TimeInterval) -> Void
    ) async throws -> [TranscribedSpan]
}
