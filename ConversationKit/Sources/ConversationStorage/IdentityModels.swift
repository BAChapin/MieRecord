import ConversationCore
import Foundation
import SwiftData

// Speaker identity storage (Milestone 3). Structured values that have no query
// needs are stored as encoded blobs so their shapes can evolve without
// SwiftData migrations. Vectors use raw Float32 bytes.

/// Window embeddings for one recording. Deleted with the recording.
@Model
final class RecordingVoiceDataRecord {
    @Attribute(.unique) var recordingID: UUID
    var engineIdentifier: String
    var engineVersion: String?
    /// JSON array of `StoredWindow`.
    @Attribute(.externalStorage) var windowsData: Data
    var recording: RecordingRecord?

    init(recordingID: UUID, engineIdentifier: String, engineVersion: String?, windowsData: Data) {
        self.recordingID = recordingID
        self.engineIdentifier = engineIdentifier
        self.engineVersion = engineVersion
        self.windowsData = windowsData
    }
}

struct StoredWindow: Codable {
    var clusterID: UUID
    var start: Double
    var end: Double
    var vector: Data
}

/// One cluster's identity decision. Deleted with the recording.
@Model
final class SpeakerAttributionRecord {
    @Attribute(.unique) var clusterID: UUID
    var recordingID: UUID
    /// JSON-encoded `SpeakerAttribution`.
    var attributionData: Data
    var recording: RecordingRecord?

    init(clusterID: UUID, recordingID: UUID, attributionData: Data) {
        self.clusterID = clusterID
        self.recordingID = recordingID
        self.attributionData = attributionData
    }
}

/// An enrolled person. Independent of recordings.
@Model
final class SpeakerProfileRecord {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \VoiceSampleRecord.profile)
    var samples: [VoiceSampleRecord] = []

    init(id: UUID, displayName: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class VoiceSampleRecord {
    @Attribute(.unique) var id: UUID
    var profileID: UUID
    var engineIdentifier: String
    var engineVersion: String?
    var vectorData: Data
    var speechSeconds: Double
    var sourceRecordingID: UUID?
    /// JSON-encoded `[TimeRange]`.
    var sourceRangesData: Data
    var createdAt: Date
    var profile: SpeakerProfileRecord?

    init(id: UUID, profileID: UUID, engineIdentifier: String, engineVersion: String?, vectorData: Data, speechSeconds: Double, sourceRecordingID: UUID?, sourceRangesData: Data, createdAt: Date) {
        self.id = id
        self.profileID = profileID
        self.engineIdentifier = engineIdentifier
        self.engineVersion = engineVersion
        self.vectorData = vectorData
        self.speechSeconds = speechSeconds
        self.sourceRecordingID = sourceRecordingID
        self.sourceRangesData = sourceRangesData
        self.createdAt = createdAt
    }
}

/// A labeled score for calibration. Deleted with its profile.
@Model
final class IdentityFeedbackRecord {
    @Attribute(.unique) var id: UUID
    var profileID: UUID
    /// JSON-encoded `IdentityFeedback`.
    var feedbackData: Data

    init(id: UUID, profileID: UUID, feedbackData: Data) {
        self.id = id
        self.profileID = profileID
        self.feedbackData = feedbackData
    }
}

extension VoiceSampleRecord {
    func toDomain() -> VoiceSample {
        VoiceSample(
            id: id,
            profileID: profileID,
            engine: EngineDescriptor(identifier: engineIdentifier, version: engineVersion),
            vector: VectorMath.decode(vectorData),
            speechSeconds: speechSeconds,
            sourceRecordingID: sourceRecordingID,
            sourceRanges: (try? JSONDecoder().decode([TimeRange].self, from: sourceRangesData)) ?? [],
            createdAt: createdAt
        )
    }
}

extension SpeakerProfileRecord {
    func toDomain() -> SpeakerProfile {
        SpeakerProfile(id: id, displayName: displayName, createdAt: createdAt, updatedAt: updatedAt)
    }
}
