import Foundation

// MARK: - Recording-local speaker structure (populated by Milestone 2 diarization)

/// A distinct voice detected within one recording. Cluster identity is
/// recording-local and implies nothing across recordings (SPEC FR-4).
public struct SpeakerCluster: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var recordingID: UUID
    /// Start time of the cluster's first turn, used for `Speaker N` numbering.
    public var firstAppearance: TimeInterval

    public init(id: UUID = UUID(), recordingID: UUID, firstAppearance: TimeInterval) {
        self.id = id
        self.recordingID = recordingID
        self.firstAppearance = firstAppearance
    }
}

/// One contiguous stretch of speech attributed to a cluster.
public struct SpeakerTurn: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var clusterID: UUID
    public var timeRange: TimeRange
    /// True when diarization flagged overlapping speech or low certainty.
    public var isUncertain: Bool

    public init(id: UUID = UUID(), clusterID: UUID, timeRange: TimeRange, isUncertain: Bool = false) {
        self.id = id
        self.clusterID = clusterID
        self.timeRange = timeRange
        self.isUncertain = isUncertain
    }
}

// MARK: - Persistent identity (populated by Milestone 3 enrollment)

/// An explicitly enrolled voice profile. Profiles are only ever created by a
/// deliberate user action, never from automatically recognized speakers.
public struct SpeakerProfile: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var displayName: String
    public var embeddingEngine: EngineDescriptor
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        embeddingEngine: EngineDescriptor,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.embeddingEngine = embeddingEngine
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Identity state of a recording-local cluster (SPEC §7).
///
/// `confidence` values are *calibrated* identity confidence in [0, 1]. Raw
/// embedding similarity must be calibrated before it is stored here; see
/// `IdentityConfidencePolicy`.
public enum SpeakerAttributionStatus: Hashable, Codable, Sendable {
    case unidentified(localSpeakerNumber: Int)
    case needsVerification(profileID: UUID, confidence: Double)
    case recognized(profileID: UUID, confidence: Double)
    /// The user explicitly chose this profile. Not a model prediction.
    case userConfirmed(profileID: UUID)

    public var profileID: UUID? {
        switch self {
        case .unidentified: nil
        case let .needsVerification(id, _), let .recognized(id, _), let .userConfirmed(id): id
        }
    }
}

/// Links a cluster to its identity decision and the evidence behind it.
public struct SpeakerAttribution: Hashable, Codable, Sendable {
    public var clusterID: UUID
    public var status: SpeakerAttributionStatus
    /// Whether quality gates (sample length, noise, margin) were satisfied.
    public var passedQualityChecks: Bool

    public init(clusterID: UUID, status: SpeakerAttributionStatus, passedQualityChecks: Bool) {
        self.clusterID = clusterID
        self.status = status
        self.passedQualityChecks = passedQualityChecks
    }
}
