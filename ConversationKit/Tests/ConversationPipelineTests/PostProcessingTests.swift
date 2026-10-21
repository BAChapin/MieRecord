import ConversationCore
import ConversationML
import ConversationPipeline
import Foundation
import Testing

@Suite("Post-recording processing and speaker corrections")
struct PostProcessingTests {
    let store = TemporaryAudioFileStore()
    let live = EngineDescriptor(identifier: "live")

    private func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
        TimedWord(text: text, timeRange: TimeRange(start: start, end: end))
    }

    /// A completed 10 s recording with a word-timed live transcript:
    /// "Hello there." (0–1.5) and "Hi. How are you?" (3–5.5).
    private func seed(_ repository: InMemoryRepository, withWords: Bool = true) async throws -> Recording {
        let id = UUID()
        let url = try store.makeFileURL(forRecordingID: id, fileExtension: "caf")
        try Data([0]).write(to: url)
        let recording = Recording(
            id: id, title: "T", duration: 10,
            audioFile: AudioFileReference(fileName: url.lastPathComponent, sampleRate: 48_000, channelCount: 1),
            recordingState: .completed
        )
        try await repository.save(recording)
        let first = [word("Hello", 0, 0.6), word(" there.", 0.6, 1.5)]
        let second = [word("Hi.", 3, 3.4), word(" How", 4, 4.3), word(" are", 4.3, 4.6), word(" you?", 4.6, 5.5)]
        try await repository.saveSegments([
            TranscriptSegment(recordingID: id, timeRange: TimeRange(start: 0, end: 1.5), text: "Hello there.", isFinal: true, source: live, words: withWords ? first : []),
            TranscriptSegment(recordingID: id, timeRange: TimeRange(start: 3, end: 5.5), text: "Hi. How are you?", isFinal: true, source: live, words: withWords ? second : []),
        ])
        return recording
    }

    /// Speaker 0 says "Hello there." and "How are you?"; speaker 1 says "Hi."
    private let threeTurns = FakeDiarizer.Behavior.turns([(0, 0, 1.6), (1, 2.9, 3.6), (0, 3.9, 5.6)])

    private func coordinator(
        _ repository: InMemoryRepository,
        diarizer: FakeDiarizer?,
        fileEngine: FakeFileTranscriptionEngine? = nil
    ) -> PostProcessingCoordinator {
        let retranscription = fileEngine.map { RetranscriptionService(repository: repository, audioFileStore: store, engine: $0) }
        return PostProcessingCoordinator(repository: repository, audioFileStore: store, retranscription: retranscription, diarizer: diarizer)
    }

    @Test("diarizes, splits by speaker, reuses the live transcript, and numbers speakers by first appearance")
    func fullRun() async throws {
        let repository = InMemoryRepository()
        let recording = try await seed(repository)
        let fileEngine = FakeFileTranscriptionEngine(.spans([]))
        let outcome = try await coordinator(repository, diarizer: FakeDiarizer(threeTurns), fileEngine: fileEngine)
            .process(recordingID: recording.id)

        #expect(outcome == .ready)
        #expect(fileEngine.calls == 0, "a final, word-timed live transcript is reused")
        let segments = try await repository.segments(forRecording: recording.id)
        #expect(segments.map(\.text) == ["Hello there.", "Hi.", "How are you?"])

        let labels = SpeakerLabels.labels(forSegments: segments)
        #expect(segments.map { labels[$0.speakerClusterID!] } == ["Speaker 1", "Speaker 2", "Speaker 1"])

        let saved = try #require(await repository.recording(id: recording.id))
        #expect(saved.processingState == .ready)
        #expect(saved.diarizationEngine?.identifier == "test.diarizer")
        let timeline = try await repository.speakerTimeline(forRecording: recording.id)
        #expect(timeline.clusters.count == 2)
        #expect(timeline.turns.allSatisfy { $0.recordingID == recording.id })
        #expect(timeline.clusters.allSatisfy { $0.recordingID == recording.id })
    }

    @Test("a transcript without word timing is repaired by a whole-file pass first")
    func repairsTranscript() async throws {
        let repository = InMemoryRepository()
        let recording = try await seed(repository, withWords: false)
        let fileEngine = FakeFileTranscriptionEngine(.spans([
            TranscribedSpan(text: "Hello there.", timeRange: TimeRange(start: 0, end: 1.5), confidence: 0.9,
                            words: [word("Hello", 0, 0.6), word(" there.", 0.6, 1.5)]),
        ]))
        try await coordinator(repository, diarizer: FakeDiarizer(threeTurns), fileEngine: fileEngine).process(recordingID: recording.id)
        #expect(fileEngine.calls == 1)
        let segments = try await repository.segments(forRecording: recording.id)
        #expect(segments.map(\.text) == ["Hello there."])
        #expect(segments[0].source.identifier == "test.file")
    }

    @Test("if transcript repair fails, the live transcript is still diarized")
    func repairFailureContinues() async throws {
        let repository = InMemoryRepository()
        let recording = try await seed(repository, withWords: false)
        let outcome = try await coordinator(repository, diarizer: FakeDiarizer(threeTurns), fileEngine: FakeFileTranscriptionEngine(.fail(.engineFailure("x"))))
            .process(recordingID: recording.id)
        let segments = try await repository.segments(forRecording: recording.id)
        #expect(segments.map(\.text) == ["Hello there.", "Hi. How are you?"])
        #expect(segments.allSatisfy { $0.speakerClusterID != nil })
        #expect(outcome == .needsReview, "the second segment mixes two speakers without word timing")
    }

    @Test("diarization failure records the failing stage and keeps the transcript")
    func diarizationFailure() async throws {
        let repository = InMemoryRepository()
        let recording = try await seed(repository)
        await #expect(throws: DiarizationError.engineFailure("fake diarizer failed")) {
            try await coordinator(repository, diarizer: FakeDiarizer(.fail)).process(recordingID: recording.id)
        }
        guard case let .failed(failure) = try await repository.recording(id: recording.id)?.processingState else {
            Issue.record("expected failure"); return
        }
        #expect(failure.stage == .diarization)
        #expect(try await repository.segments(forRecording: recording.id).count == 2)
    }

    @Test("a retry reuses a stored diarization from the same engine unless a fresh run is requested")
    func checkpointReuse() async throws {
        let repository = InMemoryRepository()
        let recording = try await seed(repository)
        let diarizer = FakeDiarizer(threeTurns)
        let coordinator = coordinator(repository, diarizer: diarizer)
        try await coordinator.process(recordingID: recording.id)
        try await coordinator.process(recordingID: recording.id)
        #expect(diarizer.calls == 1)
        try await coordinator.process(recordingID: recording.id, reuseExistingDiarization: false)
        #expect(diarizer.calls == 2)

        let upgraded = FakeDiarizer(threeTurns, version: "2")
        try await self.coordinator(repository, diarizer: upgraded).process(recordingID: recording.id)
        #expect(upgraded.calls == 1, "a different engine version re-diarizes")
    }

    @Test("without a diarizer, processing reports unavailable and changes nothing")
    func noDiarizer() async throws {
        let repository = InMemoryRepository()
        let recording = try await seed(repository)
        let coordinator = coordinator(repository, diarizer: nil)
        #expect(!coordinator.isDiarizationConfigured)
        await #expect(throws: PostProcessingError.self) {
            try await coordinator.process(recordingID: recording.id)
        }
        #expect(try await repository.recording(id: recording.id)?.processingState == .notStarted)
    }

    @Test("an unsupported diarizer is reported at the diarization stage")
    func unsupportedDiarizer() async throws {
        let repository = InMemoryRepository()
        let recording = try await seed(repository)
        await #expect(throws: PostProcessingError.diarizationUnavailable("fake diarizer unsupported")) {
            try await coordinator(repository, diarizer: FakeDiarizer(.unsupported)).process(recordingID: recording.id)
        }
    }

    @Test("speaker corrections block reprocessing until explicitly discarded")
    func correctionsProtected() async throws {
        let repository = InMemoryRepository()
        let recording = try await seed(repository)
        let coordinator = coordinator(repository, diarizer: FakeDiarizer(threeTurns))
        try await coordinator.process(recordingID: recording.id)

        let editor = SpeakerEditor(repository: repository)
        let hi = try await repository.segments(forRecording: recording.id)[1]
        let speaker1 = try #require(try await repository.segments(forRecording: recording.id)[0].speakerClusterID)
        try await editor.assign(segmentID: hi.id, inRecording: recording.id, toCluster: speaker1)

        await #expect(throws: PostProcessingError.wouldDiscardSpeakerCorrections(count: 1)) {
            try await coordinator.process(recordingID: recording.id)
        }
        try await coordinator.process(recordingID: recording.id, discardingSpeakerCorrections: true)
        let after = try await repository.segments(forRecording: recording.id)
        #expect(after.allSatisfy { !$0.speakerAssignedByUser })
        #expect(after[1].speakerClusterID != speaker1, "automatic attribution restored")
    }

    @Test("realign re-attributes a replaced transcript against the stored timeline")
    func realign() async throws {
        let repository = InMemoryRepository()
        let recording = try await seed(repository)
        let coordinator = coordinator(repository, diarizer: FakeDiarizer(threeTurns))
        #expect(try await coordinator.realign(recordingID: recording.id) == nil, "nothing to align before diarization")
        try await coordinator.process(recordingID: recording.id)

        try await repository.replaceSegments([
            TranscriptSegment(recordingID: recording.id, timeRange: TimeRange(start: 3, end: 3.5), text: "Hi.", isFinal: true, source: live,
                              words: [word("Hi.", 3, 3.4)]),
        ], forRecording: recording.id)
        #expect(try await coordinator.realign(recordingID: recording.id) == .ready)
        #expect(try await repository.segments(forRecording: recording.id)[0].speakerClusterID != nil)
    }

    @Test("merge, move to a new speaker, and confirm update labels and review state")
    func editing() async throws {
        let repository = InMemoryRepository()
        let recording = try await seed(repository)
        // Second turn overlaps the first so "Hi." starts out uncertain.
        let overlapping = FakeDiarizer(.turns([(0, 0, 1.6), (1, 2.9, 3.6), (0, 3.0, 3.5), (0, 3.9, 5.6)]))
        let outcome = try await coordinator(repository, diarizer: overlapping).process(recordingID: recording.id)
        #expect(outcome == .needsReview)
        #expect(try await repository.recording(id: recording.id)?.processingState == .needsReview)

        let editor = SpeakerEditor(repository: repository)
        var segments = try await repository.segments(forRecording: recording.id)
        let uncertain = try #require(segments.first { $0.speakerIsUncertain })
        try await editor.confirm(segmentID: uncertain.id, inRecording: recording.id)
        #expect(try await repository.recording(id: recording.id)?.processingState == .ready)

        // Move the last segment to a brand-new speaker.
        let last = try #require(segments.last)
        let newCluster = try await editor.assignToNewSpeaker(segmentID: last.id, inRecording: recording.id)
        segments = try await repository.segments(forRecording: recording.id)
        var labels = SpeakerLabels.labels(forSegments: segments)
        #expect(Set(labels.values).count == labels.count)
        #expect(labels[newCluster] != nil)

        // Merge the new speaker back into the first speaker.
        let first = try #require(segments[0].speakerClusterID)
        try await editor.merge(cluster: newCluster, into: first, inRecording: recording.id)
        segments = try await repository.segments(forRecording: recording.id)
        #expect(!segments.contains { $0.speakerClusterID == newCluster })
        #expect(try await repository.speakerTimeline(forRecording: recording.id).clusters.contains { $0.id == newCluster } == false)
        labels = SpeakerLabels.labels(forSegments: segments)
        #expect(labels[first] == "Speaker 1")

        await #expect(throws: SpeakerEditError.clusterNotFound) {
            try await editor.assign(segmentID: segments[0].id, inRecording: recording.id, toCluster: UUID())
        }
    }
}
