import Foundation

// MARK: - Persistent voice profiles (only created by explicit enrollment)

/// A person the user deliberately enrolled. Never created automatically.
public struct SpeakerProfile: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var displayName: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), displayName: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One approved voice sample for a profile: a voiceprint made from lines the
/// user selected in a recording. Profiles improve only by adding samples
/// explicitly (SPEC FR-5).
public struct VoiceSample: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var profileID: UUID
    /// Embeddings from different engines or versions are not comparable.
    public var engine: EngineDescriptor
    public var vector: [Float]
    public var speechSeconds: Double
    /// Provenance: where the approved audio came from. The recording may have
    /// been deleted since; the sample does not depend on it.
    public var sourceRecordingID: UUID?
    public var sourceRanges: [TimeRange]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        profileID: UUID,
        engine: EngineDescriptor,
        vector: [Float],
        speechSeconds: Double,
        sourceRecordingID: UUID?,
        sourceRanges: [TimeRange],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.profileID = profileID
        self.engine = engine
        self.vector = vector
        self.speechSeconds = speechSeconds
        self.sourceRecordingID = sourceRecordingID
        self.sourceRanges = sourceRanges
        self.createdAt = createdAt
    }
}

/// A profile's comparable voiceprint for one engine: the centroid of its
/// samples made by that engine.
public struct ProfileVoiceprint: Hashable, Sendable {
    public var profileID: UUID
    public var vector: [Float]
    public var sampleCount: Int

    public init(profileID: UUID, vector: [Float], sampleCount: Int) {
        self.profileID = profileID
        self.vector = vector
        self.sampleCount = sampleCount
    }

    public static func make(from samples: [VoiceSample], engine: EngineDescriptor) -> [ProfileVoiceprint] {
        Dictionary(grouping: samples.filter { $0.engine == engine }, by: \.profileID).compactMap { profileID, samples in
            VectorMath.centroid(samples.map(\.vector)).map {
                ProfileVoiceprint(profileID: profileID, vector: $0, sampleCount: samples.count)
            }
        }
    }
}

// MARK: - Per-recording attribution

/// Identity state of one recording-local cluster (SPEC §7).
///
/// `Speaker N` numbers are not stored: they are presentation, computed from
/// first appearance (see `SpeakerLabels`). Confidence lives in
/// `IdentityEvidence`, separate from the decision.
public enum SpeakerAttributionStatus: Hashable, Codable, Sendable {
    /// No identity claim. Shown as `Speaker N`.
    case unidentified
    /// Automatic match in the verification tier: name plus a verify indicator.
    case needsVerification(profileID: UUID)
    /// Automatic match in the top tier: name without indicator, still editable.
    case recognized(profileID: UUID)
    /// The user chose this person. A user override, not a model prediction.
    case userConfirmed(profileID: UUID)
    /// The user said this speaker is nobody in the library.
    case userKeptUnidentified

    public var profileID: UUID? {
        switch self {
        case .unidentified, .userKeptUnidentified: nil
        case let .needsVerification(id), let .recognized(id), let .userConfirmed(id): id
        }
    }

    /// Decisions automatic matching must never overwrite.
    public var isUserDecision: Bool {
        switch self {
        case .userConfirmed, .userKeptUnidentified: true
        case .unidentified, .needsVerification, .recognized: false
        }
    }
}

/// Reasons a cluster may not be matched, whatever its score (SPEC FR-5).
public enum IdentityQualityIssue: String, Hashable, Codable, Sendable, CaseIterable {
    case tooLittleSpeech
    case inconsistentVoice
    case ambiguousBetweenPeople
    case noCompatibleVoiceprint
}

/// What the matcher saw for a cluster. `rawSimilarity` is cosine similarity
/// and is never presented as a probability; `calibratedConfidence` is set only
/// when a validated calibration is active.
public struct IdentityEvidence: Hashable, Codable, Sendable {
    public var bestProfileID: UUID?
    public var rawSimilarity: Double?
    /// Best minus second-best similarity across profiles.
    public var margin: Double?
    public var calibratedConfidence: Double?
    public var issues: Set<IdentityQualityIssue>
    public var scoringEngine: EngineDescriptor?

    public init(
        bestProfileID: UUID? = nil,
        rawSimilarity: Double? = nil,
        margin: Double? = nil,
        calibratedConfidence: Double? = nil,
        issues: Set<IdentityQualityIssue> = [],
        scoringEngine: EngineDescriptor? = nil
    ) {
        self.bestProfileID = bestProfileID
        self.rawSimilarity = rawSimilarity
        self.margin = margin
        self.calibratedConfidence = calibratedConfidence
        self.issues = issues
        self.scoringEngine = scoringEngine
    }
}

/// The identity decision for one cluster, with its evidence.
public struct SpeakerAttribution: Hashable, Codable, Sendable {
    public var clusterID: UUID
    public var recordingID: UUID
    public var status: SpeakerAttributionStatus
    public var evidence: IdentityEvidence?
    /// People the user said this speaker is not; never suggested again.
    public var rejectedProfileIDs: Set<UUID>
    public var decidedAt: Date

    public init(
        clusterID: UUID,
        recordingID: UUID,
        status: SpeakerAttributionStatus,
        evidence: IdentityEvidence? = nil,
        rejectedProfileIDs: Set<UUID> = [],
        decidedAt: Date = Date()
    ) {
        self.clusterID = clusterID
        self.recordingID = recordingID
        self.status = status
        self.evidence = evidence
        self.rejectedProfileIDs = rejectedProfileIDs
        self.decidedAt = decidedAt
    }
}

// MARK: - Calibration data

/// A labeled score from a user decision, collected locally to calibrate
/// matching later. Contains scores only, no audio or embeddings.
public struct IdentityFeedback: Identifiable, Hashable, Codable, Sendable {
    public enum Source: String, Codable, Sendable {
        case confirmedSuggestion
        case rejectedSuggestion
        case manualAssignment
    }

    public var id: UUID
    public var profileID: UUID
    public var recordingID: UUID
    public var rawSimilarity: Double
    public var isSameSpeaker: Bool
    public var source: Source
    public var engine: EngineDescriptor
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        profileID: UUID,
        recordingID: UUID,
        rawSimilarity: Double,
        isSameSpeaker: Bool,
        source: Source,
        engine: EngineDescriptor,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.profileID = profileID
        self.recordingID = recordingID
        self.rawSimilarity = rawSimilarity
        self.isSameSpeaker = isSameSpeaker
        self.source = source
        self.engine = engine
        self.createdAt = createdAt
    }
}
