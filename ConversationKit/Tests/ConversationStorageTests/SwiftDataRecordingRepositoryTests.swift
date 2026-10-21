import ConversationCore
import ConversationStorage
import Foundation
import SwiftData
import Testing

@Suite("SwiftData recording repository")
struct SwiftDataRecordingRepositoryTests {
    private func makeRepository() throws -> SwiftDataRecordingRepository {
        let container = try ConversationStorage.makeModelContainer(inMemory: true)
        return SwiftDataRecordingRepository(modelContainer: container)
    }

    private func makeRecording(title: String = "Meeting") -> Recording {
        Recording(
            title: title,
            audioFile: AudioFileReference(fileName: "x.caf", sampleRate: 48_000, channelCount: 1),
            liveTranscriptionEngine: EngineDescriptor(identifier: "apple.speech.transcriber", version: "ios26")
        )
    }

    @Test("save inserts then updates by id")
    func upsert() async throws {
        let repository = try makeRepository()
        var recording = makeRecording()
        try await repository.save(recording)

        recording.title = "Renamed"
        recording.duration = 42
        recording.recordingState = .completed
        recording.processingState = .failed(ProcessingFailure(stage: .diarization, message: "x", occurredAt: Date(timeIntervalSince1970: 0)))
        try await repository.save(recording)

        let all = try await repository.allRecordings()
        #expect(all.count == 1)
        #expect(all.first == recording)
    }

    @Test("updateRecording changes only what the transform touches")
    func update() async throws {
        let repository = try makeRepository()
        let recording = makeRecording()
        try await repository.save(recording)
        let updated = try await repository.updateRecording(id: recording.id) { $0.title = "Renamed" }
        #expect(updated.title == "Renamed")
        #expect(updated.audioFile == recording.audioFile)
        #expect(try await repository.recording(id: recording.id) == updated)
        await #expect(throws: StorageError.recordingNotFound(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)) {
            try await repository.updateRecording(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!) { _ in }
        }
    }

    @Test("segments round-trip, upsert by id, and sort by time")
    func segments() async throws {
        let repository = try makeRepository()
        let recording = makeRecording()
        try await repository.save(recording)
        let source = EngineDescriptor(identifier: "e")

        let late = TranscriptSegment(recordingID: recording.id, timeRange: TimeRange(start: 5, end: 6), text: "late", isFinal: true, source: source, transcriptionConfidence: 0.5)
        var early = TranscriptSegment(recordingID: recording.id, timeRange: TimeRange(start: 1, end: 2), text: "early", isFinal: false, source: source)
        try await repository.saveSegments([late])
        try await repository.saveSegments([early])

        early.text = "early edited"
        early.editedAt = Date(timeIntervalSince1970: 10)
        try await repository.saveSegments([early])

        let loaded = try await repository.segments(forRecording: recording.id)
        #expect(loaded == [early, late])
    }

    @Test("replaceSegments swaps the whole set")
    func replace() async throws {
        let repository = try makeRepository()
        let recording = makeRecording()
        try await repository.save(recording)
        let source = EngineDescriptor(identifier: "e")
        try await repository.saveSegments([
            TranscriptSegment(recordingID: recording.id, timeRange: nil, text: "a", isFinal: true, source: source),
        ])
        let replacement = TranscriptSegment(recordingID: recording.id, timeRange: nil, text: "b", isFinal: true, source: source)
        try await repository.replaceSegments([replacement], forRecording: recording.id)
        #expect(try await repository.segments(forRecording: recording.id) == [replacement])
    }

    @Test("deleting a recording cascades to its segments")
    func cascadeDelete() async throws {
        let repository = try makeRepository()
        let recording = makeRecording()
        try await repository.save(recording)
        try await repository.saveSegments([
            TranscriptSegment(recordingID: recording.id, timeRange: nil, text: "a", isFinal: true, source: EngineDescriptor(identifier: "e")),
        ])
        try await repository.deleteRecording(id: recording.id)
        #expect(try await repository.recording(id: recording.id) == nil)
        #expect(try await repository.segments(forRecording: recording.id).isEmpty)
    }

    @Test("DirectoryAudioFileStore creates and removes files under its directory")
    func audioFileStore() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = DirectoryAudioFileStore(directoryURL: directory)
        let id = UUID()
        let url = try store.makeFileURL(forRecordingID: id, fileExtension: "caf")
        #expect(url.lastPathComponent == "\(id.uuidString).caf")
        #expect(url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path)
        try Data([1, 2, 3]).write(to: url)
        let reference = AudioFileReference(fileName: url.lastPathComponent, sampleRate: 1, channelCount: 1)
        #expect(store.url(for: reference) == url)
        try store.removeFile(for: reference)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
