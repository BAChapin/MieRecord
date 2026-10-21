import ConversationCore
import ConversationML
import Foundation
import OSLog

public enum PostProcessingError: Error, Equatable, Sendable, LocalizedError {
    case recordingNotFound
    case recordingInProgress
    case alreadyRunning
    case audioFileMissing
    case wouldDiscardSpeakerCorrections(count: Int)
    case diarizationUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .recordingNotFound: "The recording no longer exists."
        case .recordingInProgress: "This recording is still being captured."
        case .alreadyRunning: "This recording is already being processed."
        case .audioFileMissing: "The audio file for this recording is missing."
        case let .wouldDiscardSpeakerCorrections(count): "Processing again would discard your speaker corrections on \(count) segment(s)."
        case let .diarizationUnavailable(reason): "Speaker detection is unavailable: \(reason)"
        }
    }
}

/// Progress reported while processing.
public struct ProcessingProgress: Sendable, Equatable {
    public var stage: ProcessingStage
    /// Fraction of the current stage in [0, 1], when known.
    public var fraction: Double?

    public init(stage: ProcessingStage, fraction: Double? = nil) {
        self.stage = stage
        self.fraction = fraction
    }
}

/// Runs post-recording processing for one recording (SPEC FR-3): transcript
/// repair, diarization, voiceprint extraction, identity matching, and
/// transcript-to-speaker alignment.
///
/// Stages are independently retryable:
/// 1. **Transcription finalization.** Reuses the live transcript. Runs a
///    whole-file pass only when the transcript is missing, contains
///    provisional text, or lacks word timing, and never over user-edited text.
///    If that pass fails but a live transcript exists, processing continues
///    with it.
/// 2. **Diarization.** Persisted as soon as it completes. A retry reuses it
///    when the same engine produced it (the checkpoint), unless the caller
///    asks for a fresh run.
/// 3. **Voiceprints and identity.** Window embeddings from diarization are
///    stored with the recording; speakers are matched against enrolled people
///    (`IdentityService`). User identity decisions survive a reused diarization.
/// 4. **Alignment.** Rebuilds segment attribution from the stored timeline.
///
/// The audio file is never modified, nothing is replaced until the stage that
/// produces it succeeds, and cancellation restores the previous state.
public actor PostProcessingCoordinator {
    public enum Outcome: Sendable, Equatable {
        case ready
        case needsReview
    }

    private static let logger = Logger(subsystem: "com.mietech.MieRecord", category: "PostProcessing")

    private let repository: any RecordingRepository
    private let audioFileStore: any AudioFileStore
    private let retranscription: RetranscriptionService?
    private let diarizer: (any SpeakerDiarizationEngine)?
    private let identityRepository: (any SpeakerIdentityRepository)?
    private let identity: IdentityService?
    private var running: Set<UUID> = []

    /// Whether a diarization engine is configured at all.
    public nonisolated let isDiarizationConfigured: Bool

    public init(
        repository: any RecordingRepository,
        audioFileStore: any AudioFileStore,
        retranscription: RetranscriptionService?,
        diarizer: (any SpeakerDiarizationEngine)?,
        identityRepository: (any SpeakerIdentityRepository)? = nil,
        identity: IdentityService? = nil
    ) {
        self.repository = repository
        self.audioFileStore = audioFileStore
        self.retranscription = retranscription
        self.diarizer = diarizer
        self.identityRepository = identityRepository
        self.identity = identity
        self.isDiarizationConfigured = diarizer != nil
    }

    /// - Parameters:
    ///   - discardingSpeakerCorrections: required to re-attribute segments
    ///     whose speaker the user chose.
    ///   - reuseExistingDiarization: reuse a stored timeline from the same
    ///     engine (retry after failure). Pass `false` to diarize again.
    @discardableResult
    public func process(
        recordingID: UUID,
        discardingSpeakerCorrections: Bool = false,
        reuseExistingDiarization: Bool = true,
        progress: (@Sendable (ProcessingProgress) -> Void)? = nil
    ) async throws -> Outcome {
        guard !running.contains(recordingID) else { throw PostProcessingError.alreadyRunning }
        running.insert(recordingID)
        defer { running.remove(recordingID) }

        guard let diarizer else {
            throw PostProcessingError.diarizationUnavailable("No speaker detection engine is installed.")
        }
        guard let recording = try await repository.recording(id: recordingID) else {
            throw PostProcessingError.recordingNotFound
        }
        guard recording.recordingState != .recording else { throw PostProcessingError.recordingInProgress }

        var segments = try await repository.segments(forRecording: recordingID)
        let storedTimeline = try await repository.speakerTimeline(forRecording: recordingID)
        // Recordings diarized before voice data was stored (Milestone 2) are
        // diarized again so their speakers can be matched and enrolled.
        var hasVoiceData = true
        if let identityRepository {
            hasVoiceData = try await identityRepository.voiceData(forRecording: recordingID) != nil
        }
        let willReuseDiarization = reuseExistingDiarization
            && !storedTimeline.turns.isEmpty
            && recording.diarizationEngine == diarizer.descriptor
            && hasVoiceData
        // Line corrections are always re-attributed; identity decisions are
        // only lost when diarization runs again (cluster IDs change).
        let identityDecisions = willReuseDiarization ? 0 : try await identityRepository?
            .speakerAttributions(forRecording: recordingID).filter(\.status.isUserDecision).count ?? 0
        let corrected = segments.filter(\.speakerAssignedByUser).count + identityDecisions
        if corrected > 0, !discardingSpeakerCorrections {
            throw PostProcessingError.wouldDiscardSpeakerCorrections(count: corrected)
        }
        let url = audioFileStore.url(for: recording.audioFile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PostProcessingError.audioFileMissing
        }

        let previousState = recording.processingState
        var stage = ProcessingStage.transcriptionFinalization
        do {
            // 1. Transcription finalization
            try await setState(.processing(stage), for: recordingID)
            progress?(ProcessingProgress(stage: stage))
            if Self.needsTranscriptionPass(segments), let retranscription {
                do {
                    try await retranscription.retranscribe(recordingID: recordingID) { fraction in
                        progress?(ProcessingProgress(stage: .transcriptionFinalization, fraction: fraction))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Keep whatever transcript exists; diarization is still useful.
                    guard !segments.isEmpty else { throw error }
                    Self.logger.notice("Transcript repair failed, continuing with live transcript: \(error.localizedDescription, privacy: .public)")
                }
                segments = try await repository.segments(forRecording: recordingID)
            }
            try Task.checkCancellation()

            // 2. Diarization (checkpointed)
            stage = .diarization
            try await setState(.processing(stage), for: recordingID)
            progress?(ProcessingProgress(stage: stage, fraction: 0))
            var timeline = storedTimeline
            if !willReuseDiarization {
                switch await diarizer.availability() {
                case .available:
                    break
                case .assetsRequired:
                    try await diarizer.prepare()
                case let .unsupported(reason):
                    throw PostProcessingError.diarizationUnavailable(reason)
                }
                let output = try await diarizer.diarize(audioURL: url, recordingID: recordingID) { fraction in
                    progress?(ProcessingProgress(stage: .diarization, fraction: fraction))
                }
                try Task.checkCancellation()
                timeline = Self.owned(output.timeline, by: recordingID).normalized()
                try await repository.replaceSpeakerTimeline(timeline, forRecording: recordingID)
                // New clusters: old voice data and identity decisions no longer apply.
                if let identityRepository {
                    let kept = Set(timeline.clusters.map(\.id))
                    let voice = output.voiceData.map { data in
                        RecordingVoiceData(engine: data.engine, windows: data.windows.filter { kept.contains($0.clusterID) })
                    }
                    try await identityRepository.replaceVoiceData(voice, forRecording: recordingID)
                    try await identityRepository.replaceSpeakerAttributions([], forRecording: recordingID)
                }
                let descriptor = diarizer.descriptor
                try await repository.updateRecording(id: recordingID) { $0.diarizationEngine = descriptor }
            }
            progress?(ProcessingProgress(stage: .diarization, fraction: 1))

            // 3. Identity matching against enrolled people
            if let identity {
                stage = .identityMatching
                try await setState(.processing(stage), for: recordingID)
                progress?(ProcessingProgress(stage: stage))
                try await identity.matchSpeakers(recordingID: recordingID)
            }

            // 4. Alignment
            stage = .alignment
            try await setState(.processing(stage), for: recordingID)
            progress?(ProcessingProgress(stage: stage))
            if discardingSpeakerCorrections {
                for index in segments.indices { segments[index].speakerAssignedByUser = false }
            }
            let outcome = try await applyAlignment(segments: segments, timeline: timeline, recordingID: recordingID)
            progress?(ProcessingProgress(stage: .alignment, fraction: 1))
            return outcome
        } catch {
            if error is CancellationError || Task.isCancelled {
                try? await setState(previousState, for: recordingID)
                throw CancellationError()
            }
            Self.logger.error("Processing failed at \(stage.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? await setState(.failed(ProcessingFailure(stage: stage, message: error.localizedDescription)), for: recordingID)
            throw error
        }
    }

    /// Re-attributes the current transcript using the stored timeline, e.g.
    /// after a re-transcription replaced the segments. Returns `nil` when the
    /// recording has not been diarized.
    @discardableResult
    public func realign(recordingID: UUID) async throws -> Outcome? {
        guard !running.contains(recordingID) else { throw PostProcessingError.alreadyRunning }
        running.insert(recordingID)
        defer { running.remove(recordingID) }

        let timeline = try await repository.speakerTimeline(forRecording: recordingID)
        guard !timeline.turns.isEmpty else { return nil }
        let segments = try await repository.segments(forRecording: recordingID)
        return try await applyAlignment(segments: segments, timeline: timeline, recordingID: recordingID)
    }

    public func isRunning(recordingID: UUID) -> Bool {
        running.contains(recordingID)
    }

    // MARK: - Private

    private func applyAlignment(segments: [TranscriptSegment], timeline: SpeakerTimeline, recordingID: UUID) async throws -> Outcome {
        let aligned = TranscriptSpeakerAligner.align(segments, to: timeline)
        try await repository.replaceSegments(aligned, forRecording: recordingID)
        let attributions = try await identityRepository?.speakerAttributions(forRecording: recordingID) ?? []
        let outcome: Outcome = ReviewState.needsReview(segments: aligned, attributions: attributions) ? .needsReview : .ready
        try await setState(outcome == .ready ? .ready : .needsReview, for: recordingID)
        return outcome
    }

    /// Repair the transcript only when it is missing, provisional, or lacks
    /// word timing, and never when the user edited text.
    static func needsTranscriptionPass(_ segments: [TranscriptSegment]) -> Bool {
        guard !segments.contains(where: { $0.editedAt != nil }) else { return false }
        return segments.isEmpty || segments.contains { !$0.isFinal || $0.words.isEmpty }
    }

    /// Stamps every cluster and turn with the recording, whatever the engine set.
    private static func owned(_ timeline: SpeakerTimeline, by recordingID: UUID) -> SpeakerTimeline {
        SpeakerTimeline(
            clusters: timeline.clusters.map { var c = $0; c.recordingID = recordingID; return c },
            turns: timeline.turns.map { var t = $0; t.recordingID = recordingID; return t }
        )
    }

    private func setState(_ state: ProcessingState, for recordingID: UUID) async throws {
        try await repository.updateRecording(id: recordingID) { $0.processingState = state }
    }
}
