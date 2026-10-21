import ConversationCore
import Foundation

public enum SpeakerEditError: Error, Equatable, Sendable, LocalizedError {
    case segmentNotFound
    case clusterNotFound

    public var errorDescription: String? {
        switch self {
        case .segmentNotFound: "That part of the transcript no longer exists."
        case .clusterNotFound: "That speaker no longer exists."
        }
    }
}

/// User corrections to speaker attribution (SPEC FR-6).
///
/// Every correction is recorded as user-chosen (`speakerAssignedByUser`), so
/// automatic reprocessing will not silently undo it. Corrections never touch
/// persistent voice profiles.
public struct SpeakerEditor: Sendable {
    private let repository: any RecordingRepository
    private let identity: (any SpeakerIdentityRepository)?

    public init(repository: any RecordingRepository, identity: (any SpeakerIdentityRepository)? = nil) {
        self.repository = repository
        self.identity = identity
    }

    /// Moves one segment to an existing speaker.
    public func assign(segmentID: UUID, inRecording recordingID: UUID, toCluster clusterID: UUID) async throws {
        let timeline = try await repository.speakerTimeline(forRecording: recordingID)
        guard timeline.clusters.contains(where: { $0.id == clusterID }) else { throw SpeakerEditError.clusterNotFound }
        try await updateSegment(segmentID, inRecording: recordingID) { segment in
            segment.speakerClusterID = clusterID
            segment.speakerAssignedByUser = true
            segment.speakerIsUncertain = false
        }
        try await refreshReviewState(recordingID)
    }

    /// Moves one segment to a new speaker that exists only in this recording.
    /// - Returns: the new cluster's ID.
    @discardableResult
    public func assignToNewSpeaker(segmentID: UUID, inRecording recordingID: UUID) async throws -> UUID {
        let segments = try await repository.segments(forRecording: recordingID)
        guard let segment = segments.first(where: { $0.id == segmentID }) else { throw SpeakerEditError.segmentNotFound }
        var timeline = try await repository.speakerTimeline(forRecording: recordingID)
        let cluster = SpeakerCluster(recordingID: recordingID, firstAppearance: segment.timeRange?.start ?? 0)
        timeline.clusters.append(cluster)
        try await repository.replaceSpeakerTimeline(timeline, forRecording: recordingID)
        try await assign(segmentID: segmentID, inRecording: recordingID, toCluster: cluster.id)
        return cluster.id
    }

    /// Accepts the current attribution of an uncertain segment.
    public func confirm(segmentID: UUID, inRecording recordingID: UUID) async throws {
        try await updateSegment(segmentID, inRecording: recordingID) { segment in
            segment.speakerAssignedByUser = segment.speakerClusterID != nil
            segment.speakerIsUncertain = false
        }
        try await refreshReviewState(recordingID)
    }

    /// Folds one speaker into another for the whole recording, the default
    /// cluster-level correction when diarization split one person in two.
    public func merge(cluster sourceID: UUID, into targetID: UUID, inRecording recordingID: UUID) async throws {
        guard sourceID != targetID else { return }
        var timeline = try await repository.speakerTimeline(forRecording: recordingID)
        guard
            let source = timeline.clusters.first(where: { $0.id == sourceID }),
            let targetIndex = timeline.clusters.firstIndex(where: { $0.id == targetID })
        else { throw SpeakerEditError.clusterNotFound }

        timeline.clusters[targetIndex].firstAppearance = min(timeline.clusters[targetIndex].firstAppearance, source.firstAppearance)
        timeline.clusters.removeAll { $0.id == sourceID }
        for index in timeline.turns.indices where timeline.turns[index].clusterID == sourceID {
            timeline.turns[index].clusterID = targetID
        }

        let moved = try await repository.segments(forRecording: recordingID)
            .filter { $0.speakerClusterID == sourceID }
            .map { segment -> TranscriptSegment in
                var updated = segment
                updated.speakerClusterID = targetID
                updated.speakerAssignedByUser = true
                return updated
            }
        // Segments first: if the second write fails, segments point at a live
        // cluster rather than a deleted one.
        try await repository.saveSegments(moved)
        try await repository.replaceSpeakerTimeline(timeline, forRecording: recordingID)

        if let identity {
            // The merged speaker's voice windows now belong to the target, so
            // its voiceprint changes: drop automatic decisions for both and let
            // the caller re-run matching. A user decision on the target stays;
            // otherwise the source's user decision carries over.
            if var voice = try await identity.voiceData(forRecording: recordingID) {
                for index in voice.windows.indices where voice.windows[index].clusterID == sourceID {
                    voice.windows[index].clusterID = targetID
                }
                try await identity.replaceVoiceData(voice, forRecording: recordingID)
            }
            var attributions = try await identity.speakerAttributions(forRecording: recordingID)
            let sourceDecision = attributions.first { $0.clusterID == sourceID }
            attributions.removeAll { $0.clusterID == sourceID }
            if let index = attributions.firstIndex(where: { $0.clusterID == targetID }) {
                if !attributions[index].status.isUserDecision {
                    attributions[index].status = sourceDecision?.status.isUserDecision == true ? sourceDecision!.status : .unidentified
                }
            } else if let sourceDecision, sourceDecision.status.isUserDecision {
                var carried = sourceDecision
                carried.clusterID = targetID
                attributions.append(carried)
            }
            try await identity.replaceSpeakerAttributions(attributions, forRecording: recordingID)
        }
        try await refreshReviewState(recordingID)
    }

    // MARK: - Private

    private func updateSegment(_ segmentID: UUID, inRecording recordingID: UUID, _ change: (inout TranscriptSegment) -> Void) async throws {
        let segments = try await repository.segments(forRecording: recordingID)
        guard var segment = segments.first(where: { $0.id == segmentID }) else { throw SpeakerEditError.segmentNotFound }
        change(&segment)
        try await repository.saveSegments([segment])
    }

    private func refreshReviewState(_ recordingID: UUID) async throws {
        try await ReviewState.refresh(recordingID: recordingID, recordings: repository, identity: identity)
    }
}
