import Foundation

/// Lifecycle notifications from a capture source.
public enum AudioCaptureEvent: Sendable, Equatable {
    case started(sampleRate: Double, channelCount: Int)
    /// Seconds of audio written so far (file timeline).
    case progress(elapsed: TimeInterval)
    /// The system interrupted capture (phone call, Siri, another app).
    case interruptionBegan
    /// The interruption ended. `resumed` is false when the system did not allow
    /// automatic resumption; the file remains valid and capture stays paused.
    case interruptionEnded(resumed: Bool)
    /// The input route or engine configuration changed and capture was re-armed.
    case configurationChanged
    /// Capture could not continue. The file written so far remains intact.
    case failed(message: String)
}

/// Result of a finished capture.
public struct AudioCaptureSummary: Sendable, Equatable {
    public var fileURL: URL
    public var duration: TimeInterval
    public var sampleRate: Double
    public var channelCount: Int

    public init(fileURL: URL, duration: TimeInterval, sampleRate: Double, channelCount: Int) {
        self.fileURL = fileURL
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

/// Describes the PCM stream a capture source produces.
public struct AudioStreamDescription: Sendable, Equatable {
    public var sampleRate: Double
    public var channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

/// A source of captured audio that is simultaneously written to a durable file
/// and streamed to consumers (such as a transcription engine).
///
/// Implementations must never let a slow consumer block capture: `chunks` is a
/// bounded stream and drops oldest data for the consumer rather than stalling
/// the file writer.
public protocol AudioCaptureSource: Sendable {
    var chunks: AsyncStream<AudioChunk> { get }
    var events: AsyncStream<AudioCaptureEvent> { get }
    /// Begins capture and returns the stream format being written.
    func start() async throws -> AudioStreamDescription
    /// Stops capture, finishes both streams, and returns the final file summary.
    func stop() async throws -> AudioCaptureSummary
}

public enum AudioCaptureError: Error, Sendable, Equatable {
    case microphonePermissionDenied
    case alreadyStarted
    case notStarted
    case inputUnavailable
    case fileCreationFailed(String)
    case engineStartFailed(String)
}
