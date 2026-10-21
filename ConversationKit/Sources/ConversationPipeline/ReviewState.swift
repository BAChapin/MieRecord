import ConversationCore
import Foundation

/// Whether a processed recording needs the user's attention: lines with an
/// uncertain or missing speaker, or identity matches awaiting verification.
enum ReviewState {
    static func needsReview(segments: [TranscriptSegment], attributions: [SpeakerAttribution]) -> Bool {
        segments.contains { $0.speakerIsUncertain || $0.speakerClusterID == nil }
            || attributions.contains { if case .needsVerification = $0.status { true } else { false } }
    }

    /// Moves a processed recording between `.ready` and `.needsReview` after an
    /// edit. Other states (processing, failed, not started) are left alone.
    static func refresh(
        recordingID: UUID,
        recordings: any RecordingRepository,
        identity: (any SpeakerIdentityRepository)?
    ) async throws {
        guard let state = try await recordings.recording(id: recordingID)?.processingState,
              state == .ready || state == .needsReview else { return }
        let segments = try await recordings.segments(forRecording: recordingID)
        let attributions = try await identity?.speakerAttributions(forRecording: recordingID) ?? []
        let target: ProcessingState = needsReview(segments: segments, attributions: attributions) ? .needsReview : .ready
        if target != state {
            try await recordings.updateRecording(id: recordingID) { $0.processingState = target }
        }
    }
}
