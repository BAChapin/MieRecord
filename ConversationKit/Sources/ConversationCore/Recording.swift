import Foundation

/// Where the durable source audio for a recording lives, relative to the
/// app-managed recordings directory. Paths are relative so the app container can
/// move between launches without invalidating stored references.
public struct AudioFileReference: Hashable, Codable, Sendable {
    public var fileName: String
    public var sampleRate: Double
    public var channelCount: Int

    public init(fileName: String, sampleRate: Double, channelCount: Int) {
        self.fileName = fileName
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

/// Capture lifecycle of a recording.
public enum RecordingState: String, Codable, Sendable {
    /// Audio is still being captured. A recording left in this state after a
    /// relaunch was interrupted by termination; its file is still usable.
    case recording
    /// Capture stopped normally and the file was finalized.
    case completed
    /// Capture ended because of an unrecoverable error or app termination.
    case interrupted
}

/// A single captured conversation.
public struct Recording: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    /// Seconds of audio written to the file (file timeline, excludes paused time).
    public var duration: TimeInterval
    public var audioFile: AudioFileReference
    public var recordingState: RecordingState
    public var processingState: ProcessingState
    /// Engine that produced the live transcript, if any.
    public var liveTranscriptionEngine: EngineDescriptor?
    /// Engine that produced the stored speaker clusters and turns, if any.
    /// Used to reuse a completed diarization when processing is retried.
    public var diarizationEngine: EngineDescriptor?

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        duration: TimeInterval = 0,
        audioFile: AudioFileReference,
        recordingState: RecordingState = .recording,
        processingState: ProcessingState = .notStarted,
        liveTranscriptionEngine: EngineDescriptor? = nil,
        diarizationEngine: EngineDescriptor? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.audioFile = audioFile
        self.recordingState = recordingState
        self.processingState = processingState
        self.liveTranscriptionEngine = liveTranscriptionEngine
        self.diarizationEngine = diarizationEngine
    }
}
