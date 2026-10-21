import Foundation

/// Persistence boundary for recordings and their transcript segments.
///
/// Implementations must be safe to call from any isolation domain; the
/// SwiftData implementation lives in ConversationStorage. Returning value types
/// keeps SwiftData model objects out of the pipeline and UI layers.
public protocol RecordingRepository: Sendable {
    func allRecordings() async throws -> [Recording]
    func recording(id: UUID) async throws -> Recording?
    /// Inserts or updates by `id`.
    func save(_ recording: Recording) async throws
    /// Reads, transforms, and saves one recording in a single repository step,
    /// so concurrent writers (rename, processing state) do not overwrite each
    /// other's fields with stale copies. Returns the saved value.
    @discardableResult
    func updateRecording(id: UUID, _ transform: @Sendable (inout Recording) -> Void) async throws -> Recording
    /// Deletes the recording and its segments. The audio file is the caller's
    /// responsibility (see `AudioFileStore`).
    func deleteRecording(id: UUID) async throws

    func segments(forRecording recordingID: UUID) async throws -> [TranscriptSegment]
    /// Inserts or updates each segment by `id`.
    func saveSegments(_ segments: [TranscriptSegment]) async throws
    /// Replaces every segment of the recording with `segments`.
    func replaceSegments(_ segments: [TranscriptSegment], forRecording recordingID: UUID) async throws

    /// Speaker clusters and turns stored for the recording (empty before
    /// diarization).
    func speakerTimeline(forRecording recordingID: UUID) async throws -> SpeakerTimeline
    /// Replaces the recording's clusters and turns in one save.
    func replaceSpeakerTimeline(_ timeline: SpeakerTimeline, forRecording recordingID: UUID) async throws
}

/// Persistence for speaker identity: per-recording voice data and attributions,
/// and the persistent profile library.
///
/// Voice data belongs to a recording and is deleted with it. Profiles and
/// their samples are independent of recordings and are only created, changed,
/// or deleted by explicit user actions.
public protocol SpeakerIdentityRepository: Sendable {
    func voiceData(forRecording recordingID: UUID) async throws -> RecordingVoiceData?
    func replaceVoiceData(_ data: RecordingVoiceData?, forRecording recordingID: UUID) async throws

    func speakerAttributions(forRecording recordingID: UUID) async throws -> [SpeakerAttribution]
    /// Replaces all attributions for the recording in one save.
    func replaceSpeakerAttributions(_ attributions: [SpeakerAttribution], forRecording recordingID: UUID) async throws

    func speakerProfiles() async throws -> [SpeakerProfile]
    func saveSpeakerProfile(_ profile: SpeakerProfile) async throws
    /// Deletes the profile, its samples, and its feedback records.
    func deleteSpeakerProfile(id: UUID) async throws
    func voiceSamples(forProfile profileID: UUID?) async throws -> [VoiceSample]
    func saveVoiceSample(_ sample: VoiceSample) async throws
    func deleteVoiceSample(id: UUID) async throws

    func saveIdentityFeedback(_ feedback: IdentityFeedback) async throws
    func identityFeedback() async throws -> [IdentityFeedback]
}

/// Resolves `AudioFileReference`s to concrete URLs inside an app-managed
/// directory and owns deletion of audio files.
public protocol AudioFileStore: Sendable {
    /// A new, unused URL for a recording's audio file.
    func makeFileURL(forRecordingID id: UUID, fileExtension: String) throws -> URL
    func url(for reference: AudioFileReference) -> URL
    func removeFile(for reference: AudioFileReference) throws
}

/// Errors shared across storage implementations.
public enum StorageError: Error, Equatable, Sendable {
    case recordingNotFound(UUID)
    case encodingFailed(String)
}
