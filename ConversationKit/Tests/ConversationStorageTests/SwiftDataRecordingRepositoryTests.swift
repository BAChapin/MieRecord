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

    @Test("word timings, speaker flags, and the speaker timeline round-trip")
    func speakerData() async throws {
        let repository = try makeRepository()
        let recording = makeRecording()
        try await repository.save(recording)
        let cluster = SpeakerCluster(recordingID: recording.id, firstAppearance: 1)
        let turn = SpeakerTurn(recordingID: recording.id, clusterID: cluster.id, timeRange: TimeRange(start: 1, end: 2), isUncertain: true)
        try await repository.replaceSpeakerTimeline(SpeakerTimeline(clusters: [cluster], turns: [turn]), forRecording: recording.id)
        #expect(try await repository.speakerTimeline(forRecording: recording.id) == SpeakerTimeline(clusters: [cluster], turns: [turn]))

        let segment = TranscriptSegment(
            recordingID: recording.id, timeRange: TimeRange(start: 1, end: 2), text: "Hi there", isFinal: true,
            source: EngineDescriptor(identifier: "e"), speakerClusterID: cluster.id,
            words: [TimedWord(text: "Hi", timeRange: TimeRange(start: 1, end: 1.4), confidence: 0.9),
                    TimedWord(text: " there", timeRange: TimeRange(start: 1.4, end: 2))],
            speakerAssignedByUser: true, speakerIsUncertain: true
        )
        try await repository.saveSegments([segment])
        #expect(try await repository.segments(forRecording: recording.id) == [segment])

        var updated = recording
        updated.diarizationEngine = EngineDescriptor(identifier: "d", version: "2")
        try await repository.save(updated)
        #expect(try await repository.recording(id: recording.id)?.diarizationEngine == updated.diarizationEngine)

        try await repository.replaceSpeakerTimeline(.empty, forRecording: recording.id)
        #expect(try await repository.speakerTimeline(forRecording: recording.id) == .empty)

        try await repository.replaceSpeakerTimeline(SpeakerTimeline(clusters: [cluster], turns: [turn]), forRecording: recording.id)
        try await repository.deleteRecording(id: recording.id)
        #expect(try await repository.speakerTimeline(forRecording: recording.id) == .empty, "cascade delete")
    }

    @Test("identity data round-trips; recording deletion removes its voice data; profile deletion removes samples and feedback")
    func identityData() async throws {
        let repository = try makeRepository()
        let recording = makeRecording()
        try await repository.save(recording)
        let engine = EngineDescriptor(identifier: "d", version: "1")
        let cluster = UUID()
        let voice = RecordingVoiceData(engine: engine, windows: [
            WindowEmbedding(clusterID: cluster, timeRange: TimeRange(start: 0, end: 10), vector: [0.5, -0.25, 1]),
        ])
        try await repository.replaceVoiceData(voice, forRecording: recording.id)
        #expect(try await repository.voiceData(forRecording: recording.id) == voice)

        let profile = SpeakerProfile(displayName: "Brett", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
        try await repository.saveSpeakerProfile(profile)
        let attribution = SpeakerAttribution(
            clusterID: cluster, recordingID: recording.id, status: .needsVerification(profileID: profile.id),
            evidence: IdentityEvidence(bestProfileID: profile.id, rawSimilarity: 0.78, margin: 0.3, issues: [], scoringEngine: engine),
            rejectedProfileIDs: [UUID()], decidedAt: Date(timeIntervalSince1970: 3)
        )
        try await repository.replaceSpeakerAttributions([attribution], forRecording: recording.id)
        #expect(try await repository.speakerAttributions(forRecording: recording.id) == [attribution])

        let sample = VoiceSample(profileID: profile.id, engine: engine, vector: [1, 0, 0], speechSeconds: 12,
                                 sourceRecordingID: recording.id, sourceRanges: [TimeRange(start: 0, end: 12)],
                                 createdAt: Date(timeIntervalSince1970: 4))
        try await repository.saveVoiceSample(sample)
        #expect(try await repository.voiceSamples(forProfile: profile.id) == [sample])
        let feedback = IdentityFeedback(profileID: profile.id, recordingID: recording.id, rawSimilarity: 0.8, isSameSpeaker: true,
                                        source: .confirmedSuggestion, engine: engine, createdAt: Date(timeIntervalSince1970: 5))
        try await repository.saveIdentityFeedback(feedback)
        #expect(try await repository.identityFeedback() == [feedback])

        try await repository.deleteRecording(id: recording.id)
        #expect(try await repository.voiceData(forRecording: recording.id) == nil)
        #expect(try await repository.speakerAttributions(forRecording: recording.id).isEmpty)
        #expect(try await repository.voiceSamples(forProfile: profile.id) == [sample], "profiles do not depend on recordings")

        try await repository.deleteSpeakerProfile(id: profile.id)
        #expect(try await repository.speakerProfiles().isEmpty)
        #expect(try await repository.voiceSamples(forProfile: nil).isEmpty)
        #expect(try await repository.identityFeedback().isEmpty)
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
