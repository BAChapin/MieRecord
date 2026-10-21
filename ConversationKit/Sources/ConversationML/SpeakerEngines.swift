import ConversationCore
import Foundation

// Interface for post-recording speaker processing (SPEC §6). The diarization
// engine also supplies the speaker embeddings used for identity matching, so
// clustering and matching share one embedding space.

/// Produces speaker turns and recording-local clusters from a finished recording.
///
/// Implementations run fully on device once their model assets are present,
/// read the audio file without modifying it, and report times on the file's
/// own timeline. Cluster IDs only need to be unique within the result.
public protocol SpeakerDiarizationEngine: Sendable {
    var descriptor: EngineDescriptor { get }
    func availability() async -> EngineAvailability
    /// Installs model assets when `availability()` is `.assetsRequired`.
    func prepare() async throws
    /// - Parameter progress: fraction complete in [0, 1], when the engine can tell.
    func diarize(
        audioURL: URL,
        recordingID: UUID,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DiarizationOutput
}

/// Diarization result: who spoke when, plus the per-window speaker embeddings
/// identity matching uses. Window cluster IDs refer to `timeline` clusters.
/// Engines that cannot produce embeddings return `voiceData == nil`, which
/// leaves every speaker unidentified.
public struct DiarizationOutput: Sendable, Equatable {
    public var timeline: SpeakerTimeline
    public var voiceData: RecordingVoiceData?

    public init(timeline: SpeakerTimeline, voiceData: RecordingVoiceData? = nil) {
        self.timeline = timeline
        self.voiceData = voiceData
    }
}

public enum DiarizationError: Error, Equatable, Sendable, LocalizedError {
    case audioFileUnreadable(String)
    case modelUnavailable(String)
    case engineFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .audioFileUnreadable(reason): "The audio file could not be read: \(reason)"
        case let .modelUnavailable(reason): "The speaker model is unavailable: \(reason)"
        case let .engineFailure(reason): reason
        }
    }
}
