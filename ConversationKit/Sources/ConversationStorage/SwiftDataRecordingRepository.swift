import ConversationCore
import Foundation
import SwiftData

/// Creates the app's SwiftData container. `inMemory` is used by tests and previews.
public enum ConversationStorage {
    public static let schema = Schema([
        RecordingRecord.self,
        TranscriptSegmentRecord.self,
        SpeakerClusterRecord.self,
        SpeakerTurnRecord.self,
        RecordingVoiceDataRecord.self,
        SpeakerAttributionRecord.self,
        SpeakerProfileRecord.self,
        VoiceSampleRecord.self,
        IdentityFeedbackRecord.self,
    ])

    /// Opens an existing store file directly. Used to verify that stores
    /// written by earlier app versions still open after schema changes.
    public static func makeModelContainer(storeURL: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    public static func makeModelContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "MieRecord",
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

/// SwiftData-backed `RecordingRepository`. Being a `@ModelActor`, every access
/// to the model context runs on this actor's executor, which keeps SwiftData
/// off the main actor and satisfies strict concurrency.
@ModelActor
public actor SwiftDataRecordingRepository: RecordingRepository, SpeakerIdentityRepository {
    public func allRecordings() async throws -> [Recording] {
        let descriptor = FetchDescriptor<RecordingRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return try modelContext.fetch(descriptor).map { $0.toDomain() }
    }

    public func recording(id: UUID) async throws -> Recording? {
        try fetchRecord(id: id)?.toDomain()
    }

    public func save(_ recording: Recording) async throws {
        if let existing = try fetchRecord(id: recording.id) {
            try existing.update(from: recording)
        } else {
            modelContext.insert(try RecordingRecord(from: recording))
        }
        try modelContext.save()
    }

    @discardableResult
    public func updateRecording(id: UUID, _ transform: @Sendable (inout Recording) -> Void) async throws -> Recording {
        guard let record = try fetchRecord(id: id) else { throw StorageError.recordingNotFound(id) }
        var recording = record.toDomain()
        transform(&recording)
        recording.id = id
        try record.update(from: recording)
        try modelContext.save()
        return recording
    }

    public func deleteRecording(id: UUID) async throws {
        guard let record = try fetchRecord(id: id) else { return }
        modelContext.delete(record)
        try modelContext.save()
    }

    public func segments(forRecording recordingID: UUID) async throws -> [TranscriptSegment] {
        let descriptor = FetchDescriptor<TranscriptSegmentRecord>(
            predicate: #Predicate { $0.recordingID == recordingID },
            sortBy: [SortDescriptor(\.orderIndex)]
        )
        return try modelContext.fetch(descriptor).map { $0.toDomain() }.sortedByTime()
    }

    public func saveSegments(_ segments: [TranscriptSegment]) async throws {
        guard !segments.isEmpty else { return }
        var nextOrder = try maxOrderIndex(forRecording: segments[0].recordingID) + 1
        for segment in segments {
            if let existing = try fetchSegment(id: segment.id) {
                existing.update(from: segment)
            } else {
                let record = TranscriptSegmentRecord(from: segment, orderIndex: nextOrder)
                nextOrder += 1
                record.recording = try fetchRecord(id: segment.recordingID)
                modelContext.insert(record)
            }
        }
        try modelContext.save()
    }

    public func replaceSegments(_ segments: [TranscriptSegment], forRecording recordingID: UUID) async throws {
        // Deleted one by one: a batch delete bypasses the relationship inverse
        // and SwiftData rejects it with a constraint violation.
        let existing = try modelContext.fetch(
            FetchDescriptor<TranscriptSegmentRecord>(predicate: #Predicate { $0.recordingID == recordingID })
        )
        for record in existing {
            modelContext.delete(record)
        }
        let owner = try fetchRecord(id: recordingID)
        for (index, segment) in segments.enumerated() {
            let record = TranscriptSegmentRecord(from: segment, orderIndex: index)
            record.recording = owner
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    public func speakerTimeline(forRecording recordingID: UUID) async throws -> SpeakerTimeline {
        let clusters = try modelContext.fetch(FetchDescriptor<SpeakerClusterRecord>(
            predicate: #Predicate { $0.recordingID == recordingID },
            sortBy: [SortDescriptor(\.firstAppearance)]
        ))
        let turns = try modelContext.fetch(FetchDescriptor<SpeakerTurnRecord>(
            predicate: #Predicate { $0.recordingID == recordingID },
            sortBy: [SortDescriptor(\.startTime)]
        ))
        return SpeakerTimeline(clusters: clusters.map { $0.toDomain() }, turns: turns.map { $0.toDomain() })
    }

    public func replaceSpeakerTimeline(_ timeline: SpeakerTimeline, forRecording recordingID: UUID) async throws {
        // Per-record deletes; batch deletes violate the relationship inverse.
        for record in try modelContext.fetch(FetchDescriptor<SpeakerTurnRecord>(predicate: #Predicate { $0.recordingID == recordingID })) {
            modelContext.delete(record)
        }
        for record in try modelContext.fetch(FetchDescriptor<SpeakerClusterRecord>(predicate: #Predicate { $0.recordingID == recordingID })) {
            modelContext.delete(record)
        }
        let owner = try fetchRecord(id: recordingID)
        for cluster in timeline.clusters {
            let record = SpeakerClusterRecord(id: cluster.id, recordingID: recordingID, firstAppearance: cluster.firstAppearance)
            record.recording = owner
            modelContext.insert(record)
        }
        for turn in timeline.turns {
            let record = SpeakerTurnRecord(
                id: turn.id,
                recordingID: recordingID,
                clusterID: turn.clusterID,
                startTime: turn.timeRange.start,
                endTime: turn.timeRange.end,
                isUncertain: turn.isUncertain
            )
            record.recording = owner
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    // MARK: - Speaker identity

    public func voiceData(forRecording recordingID: UUID) async throws -> RecordingVoiceData? {
        guard let record = try fetchVoiceData(recordingID) else { return nil }
        let windows = try JSONDecoder().decode([StoredWindow].self, from: record.windowsData).map {
            WindowEmbedding(clusterID: $0.clusterID, timeRange: TimeRange(start: $0.start, end: $0.end), vector: VectorMath.decode($0.vector))
        }
        return RecordingVoiceData(engine: EngineDescriptor(identifier: record.engineIdentifier, version: record.engineVersion), windows: windows)
    }

    public func replaceVoiceData(_ data: RecordingVoiceData?, forRecording recordingID: UUID) async throws {
        if let existing = try fetchVoiceData(recordingID) {
            modelContext.delete(existing)
        }
        if let data {
            let windows = data.windows.map {
                StoredWindow(clusterID: $0.clusterID, start: $0.timeRange.start, end: $0.timeRange.end, vector: VectorMath.encode($0.vector))
            }
            let record = RecordingVoiceDataRecord(
                recordingID: recordingID,
                engineIdentifier: data.engine.identifier,
                engineVersion: data.engine.version,
                windowsData: try JSONEncoder().encode(windows)
            )
            record.recording = try fetchRecord(id: recordingID)
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    public func speakerAttributions(forRecording recordingID: UUID) async throws -> [SpeakerAttribution] {
        try modelContext.fetch(FetchDescriptor<SpeakerAttributionRecord>(predicate: #Predicate { $0.recordingID == recordingID }))
            .compactMap { try? JSONDecoder().decode(SpeakerAttribution.self, from: $0.attributionData) }
    }

    public func replaceSpeakerAttributions(_ attributions: [SpeakerAttribution], forRecording recordingID: UUID) async throws {
        for record in try modelContext.fetch(FetchDescriptor<SpeakerAttributionRecord>(predicate: #Predicate { $0.recordingID == recordingID })) {
            modelContext.delete(record)
        }
        let owner = try fetchRecord(id: recordingID)
        for attribution in attributions {
            let record = SpeakerAttributionRecord(
                clusterID: attribution.clusterID,
                recordingID: recordingID,
                attributionData: try JSONEncoder().encode(attribution)
            )
            record.recording = owner
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    public func speakerProfiles() async throws -> [SpeakerProfile] {
        try modelContext.fetch(FetchDescriptor<SpeakerProfileRecord>(sortBy: [SortDescriptor(\.displayName)])).map { $0.toDomain() }
    }

    public func saveSpeakerProfile(_ profile: SpeakerProfile) async throws {
        if let existing = try fetchProfile(profile.id) {
            existing.displayName = profile.displayName
            existing.createdAt = profile.createdAt
            existing.updatedAt = profile.updatedAt
        } else {
            modelContext.insert(SpeakerProfileRecord(id: profile.id, displayName: profile.displayName, createdAt: profile.createdAt, updatedAt: profile.updatedAt))
        }
        try modelContext.save()
    }

    public func deleteSpeakerProfile(id: UUID) async throws {
        if let record = try fetchProfile(id) {
            modelContext.delete(record) // cascades to samples
        }
        for feedback in try modelContext.fetch(FetchDescriptor<IdentityFeedbackRecord>(predicate: #Predicate { $0.profileID == id })) {
            modelContext.delete(feedback)
        }
        try modelContext.save()
    }

    public func voiceSamples(forProfile profileID: UUID?) async throws -> [VoiceSample] {
        let descriptor: FetchDescriptor<VoiceSampleRecord>
        if let profileID {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.profileID == profileID }, sortBy: [SortDescriptor(\.createdAt)])
        } else {
            descriptor = FetchDescriptor(sortBy: [SortDescriptor(\.createdAt)])
        }
        return try modelContext.fetch(descriptor).map { $0.toDomain() }
    }

    public func saveVoiceSample(_ sample: VoiceSample) async throws {
        guard let profile = try fetchProfile(sample.profileID) else {
            throw StorageError.encodingFailed("Voice sample refers to a missing profile.")
        }
        let record = VoiceSampleRecord(
            id: sample.id,
            profileID: sample.profileID,
            engineIdentifier: sample.engine.identifier,
            engineVersion: sample.engine.version,
            vectorData: VectorMath.encode(sample.vector),
            speechSeconds: sample.speechSeconds,
            sourceRecordingID: sample.sourceRecordingID,
            sourceRangesData: try JSONEncoder().encode(sample.sourceRanges),
            createdAt: sample.createdAt
        )
        record.profile = profile
        modelContext.insert(record)
        try modelContext.save()
    }

    public func deleteVoiceSample(id: UUID) async throws {
        for record in try modelContext.fetch(FetchDescriptor<VoiceSampleRecord>(predicate: #Predicate { $0.id == id })) {
            modelContext.delete(record)
        }
        try modelContext.save()
    }

    public func saveIdentityFeedback(_ feedback: IdentityFeedback) async throws {
        modelContext.insert(IdentityFeedbackRecord(id: feedback.id, profileID: feedback.profileID, feedbackData: try JSONEncoder().encode(feedback)))
        try modelContext.save()
    }

    public func identityFeedback() async throws -> [IdentityFeedback] {
        try modelContext.fetch(FetchDescriptor<IdentityFeedbackRecord>())
            .compactMap { try? JSONDecoder().decode(IdentityFeedback.self, from: $0.feedbackData) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Private

    private func fetchVoiceData(_ recordingID: UUID) throws -> RecordingVoiceDataRecord? {
        var descriptor = FetchDescriptor<RecordingVoiceDataRecord>(predicate: #Predicate { $0.recordingID == recordingID })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchProfile(_ id: UUID) throws -> SpeakerProfileRecord? {
        var descriptor = FetchDescriptor<SpeakerProfileRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchRecord(id: UUID) throws -> RecordingRecord? {
        var descriptor = FetchDescriptor<RecordingRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchSegment(id: UUID) throws -> TranscriptSegmentRecord? {
        var descriptor = FetchDescriptor<TranscriptSegmentRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func maxOrderIndex(forRecording recordingID: UUID) throws -> Int {
        var descriptor = FetchDescriptor<TranscriptSegmentRecord>(
            predicate: #Predicate { $0.recordingID == recordingID },
            sortBy: [SortDescriptor(\.orderIndex, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.orderIndex ?? -1
    }
}
