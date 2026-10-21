import ConversationCore
import Foundation
import SwiftData

/// Creates the app's SwiftData container. `inMemory` is used by tests and previews.
public enum ConversationStorage {
    public static let schema = Schema([RecordingRecord.self, TranscriptSegmentRecord.self])

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
public actor SwiftDataRecordingRepository: RecordingRepository {
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

    // MARK: - Private

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
