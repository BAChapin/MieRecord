import ConversationCore
import ConversationML
import Foundation

public enum RetranscriptionError: Error, Equatable, Sendable, LocalizedError {
    case recordingNotFound
    case recordingInProgress
    case alreadyRunning
    case audioFileMissing
    case wouldDiscardUserEdits(count: Int)
    case noSpeechDetected
    case engineUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .recordingNotFound: "The recording no longer exists."
        case .recordingInProgress: "This recording is still being captured."
        case .alreadyRunning: "This recording is already being transcribed."
        case .audioFileMissing: "The audio file for this recording is missing."
        case let .wouldDiscardUserEdits(count): "Re-transcribing would discard your corrections to \(count) transcript segment(s)."
        case .noSpeechDetected: "No speech was detected. The previous transcript was kept."
        case let .engineUnavailable(reason): "Transcription is unavailable: \(reason)"
        }
    }
}

/// Re-transcribes a saved recording from its audio file and replaces the
/// stored transcript.
///
/// Safety rules:
/// - The audio file is only read, never modified.
/// - The old transcript is replaced in one step, and only after the new pass
///   succeeds. Failure, cancellation, or an empty result keeps it.
/// - User-edited segments are authoritative (SPEC FR-6); they are only
///   discarded when the caller passes `discardingUserEdits: true`.
/// - `processingState` shows `.processing(.transcriptionFinalization)` while
///   running and `.failed` with a reason on error, so the UI and launch-time
///   recovery can represent interrupted jobs.
public actor RetranscriptionService {
    private let repository: any RecordingRepository
    private let audioFileStore: any AudioFileStore
    private let engine: any FileTranscriptionEngine
    private var running: Set<UUID> = []

    public init(
        repository: any RecordingRepository,
        audioFileStore: any AudioFileStore,
        engine: any FileTranscriptionEngine
    ) {
        self.repository = repository
        self.audioFileStore = audioFileStore
        self.engine = engine
    }

    /// - Parameter progress: fraction of the recording processed, in [0, 1].
    /// - Returns: the new transcript segments.
    @discardableResult
    public func retranscribe(
        recordingID: UUID,
        discardingUserEdits: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [TranscriptSegment] {
        // Claim the recording before any suspension point; the actor is
        // reentrant across awaits.
        guard !running.contains(recordingID) else { throw RetranscriptionError.alreadyRunning }
        running.insert(recordingID)
        defer { running.remove(recordingID) }

        guard let recording = try await repository.recording(id: recordingID) else {
            throw RetranscriptionError.recordingNotFound
        }
        guard recording.recordingState != .recording else { throw RetranscriptionError.recordingInProgress }

        let existing = try await repository.segments(forRecording: recordingID)
        // Text edits and manual speaker choices are both lost on replacement.
        let editedCount = existing.filter(\.hasUserEdits).count
        if editedCount > 0, !discardingUserEdits {
            throw RetranscriptionError.wouldDiscardUserEdits(count: editedCount)
        }

        let previousState = recording.processingState
        let url = audioFileStore.url(for: recording.audioFile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? await setState(.failed(ProcessingFailure(stage: .transcriptionFinalization, message: RetranscriptionError.audioFileMissing.localizedDescription)), for: recordingID)
            throw RetranscriptionError.audioFileMissing
        }

        try await setState(.processing(.transcriptionFinalization), for: recordingID)
        do {
            switch await engine.availability() {
            case .available:
                break
            case .assetsRequired:
                try await engine.prepare()
            case let .unsupported(reason):
                throw RetranscriptionError.engineUnavailable(reason)
            }

            let duration = recording.duration
            let spans = try await engine.transcribeFile(at: url) { seconds in
                guard duration > 0 else { return }
                progress?(min(1, max(0, seconds / duration)))
            }
            try Task.checkCancellation()

            let source = engine.fileDescriptor
            let segments = spans.compactMap { span -> TranscriptSegment? in
                let text = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(
                    recordingID: recordingID,
                    timeRange: span.timeRange,
                    text: text,
                    isFinal: true,
                    source: source,
                    transcriptionConfidence: span.confidence,
                    words: span.words
                )
            }
            if segments.isEmpty, !existing.isEmpty {
                throw RetranscriptionError.noSpeechDetected
            }

            try await repository.replaceSegments(segments, forRecording: recordingID)
            try await setState(Self.stateAfterSuccess(previous: previousState), for: recordingID)
            progress?(1)
            return segments
        } catch {
            if error is CancellationError || Task.isCancelled {
                try? await setState(previousState, for: recordingID)
                throw CancellationError()
            }
            try? await setState(
                .failed(ProcessingFailure(stage: .transcriptionFinalization, message: error.localizedDescription)),
                for: recordingID
            )
            throw error
        }
    }

    public func isRunning(recordingID: UUID) -> Bool {
        running.contains(recordingID)
    }

    // MARK: - Private

    /// A successful pass clears a previous failure or stuck state; any other
    /// state (e.g. a future `.ready` from full post-processing) is preserved.
    private static func stateAfterSuccess(previous: ProcessingState) -> ProcessingState {
        switch previous {
        case .failed, .processing, .queued: .notStarted
        case .notStarted, .needsReview, .ready: previous
        }
    }

    private func setState(_ state: ProcessingState, for recordingID: UUID) async throws {
        try await repository.updateRecording(id: recordingID) { $0.processingState = state }
    }
}
