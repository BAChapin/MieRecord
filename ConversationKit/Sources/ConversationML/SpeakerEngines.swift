import ConversationCore
import Foundation

// Interfaces for post-recording speaker processing (SPEC §6). No implementation
// ships in Milestone 1; they exist so the pipeline, storage, and UI can be built
// against stable boundaries and so an engine can be swapped without touching the
// domain model.

/// Produces speaker turns and recording-local clusters from a finished recording.
public protocol SpeakerDiarizationEngine: Sendable {
    var descriptor: EngineDescriptor { get }
    func diarize(audioURL: URL) async throws -> DiarizationResult
}

public struct DiarizationResult: Sendable, Equatable {
    public var clusters: [SpeakerCluster]
    public var turns: [SpeakerTurn]

    public init(clusters: [SpeakerCluster], turns: [SpeakerTurn]) {
        self.clusters = clusters
        self.turns = turns
    }
}

/// A fixed-length voice embedding plus the engine that produced it.
public struct SpeakerEmbedding: Sendable, Equatable {
    public var vector: [Float]
    public var engine: EngineDescriptor

    public init(vector: [Float], engine: EngineDescriptor) {
        self.vector = vector
        self.engine = engine
    }
}

/// Extracts one embedding per set of intervals (one cluster's speech).
public protocol SpeakerEmbeddingEngine: Sendable {
    var descriptor: EngineDescriptor { get }
    func embed(audioURL: URL, intervals: [TimeRange]) async throws -> SpeakerEmbedding
}

/// Compares a cluster embedding against enrolled profiles and returns a
/// **calibrated** candidate, or `nil` when no claim should be made.
///
/// Implementations are responsible for calibration and quality gates. Until a
/// validated calibration exists, an implementation must return `nil` (or a
/// candidate with `passedQualityChecks == false`) rather than expose raw
/// similarity as confidence.
public protocol SpeakerIdentityMatcher: Sendable {
    func match(
        _ embedding: SpeakerEmbedding,
        against profiles: [SpeakerProfile]
    ) async throws -> IdentityConfidencePolicy.Candidate?
}
