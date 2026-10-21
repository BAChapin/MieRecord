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
