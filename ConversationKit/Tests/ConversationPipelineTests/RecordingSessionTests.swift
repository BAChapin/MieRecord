import ConversationAudio
import ConversationCore
import ConversationML
import ConversationPipeline
import Foundation
import Testing

@Suite("RecordingSession orchestration")
struct RecordingSessionTests {
    private func makeDependencies(
        repository: InMemoryRepository,
        engine: (any StreamingTranscriptionEngine)?,
        failStart: Bool = false
    ) -> (RecordingSessionDependencies, TemporaryAudioFileStore) {
        let store = TemporaryAudioFileStore()
        let deps = RecordingSessionDependencies(
            repository: repository,
            audioFileStore: store,
            transcriptionEngine: engine,
            makeCaptureSource: { url in FakeCaptureSource(fileURL: url, failStart: failStart) },
            transcriptionFinalizationTimeout: .seconds(5)
        )
        return (deps, store)
    }

    @Test("a full session persists the recording before capture, segments as they finalize, and the completed recording on stop")
    func happyPath() async throws {
        let repository = InMemoryRepository()
        let range = TimeRange(start: 0, end: 1)
        let engine = FakeTranscriptionEngine(behavior: .script([
            .volatile(text: "hel", timeRange: range),
            .finalized(text: "hello", timeRange: range, confidence: 0.8),
            .finalized(text: "world", timeRange: TimeRange(start: 1, end: 2), confidence: nil),
            .volatile(text: "trailing", timeRange: TimeRange(start: 2, end: 3)),
        ]))
        let (deps, _) = makeDependencies(repository: repository, engine: engine)
        let session = RecordingSession(title: "Test", dependencies: deps)

        let collector = Task { () -> [RecordingSessionEvent] in
            var collected: [RecordingSessionEvent] = []
            for await event in session.events { collected.append(event) }
            return collected
        }

        try await session.start()
        let afterStart = try #require(await repository.recording(id: session.recordingID))
        #expect(afterStart.recordingState == .recording)
        #expect(afterStart.audioFile.sampleRate == 16_000)
        #expect(afterStart.liveTranscriptionEngine?.identifier == "test.engine")

        let finished = try await session.stop()
        #expect(finished.recordingState == .completed)
        #expect(finished.duration == 3)

        let segments = try await repository.segments(forRecording: session.recordingID)
        #expect(segments.map(\.text) == ["hello", "world", "trailing"])
        #expect(segments.map(\.isFinal) == [true, true, false])

        let events = await collector.value
        #expect(events.contains(.state(.recording)))
        #expect(events.contains(.state(.finished)))
        #expect(events.contains(.transcription(.active)))
        #expect(events.contains(.elapsed(0.2)))
        let finalTranscript = events.compactMap { event -> LiveTranscript? in
            if case let .transcript(t) = event { return t }
            return nil
        }.last
        #expect(finalTranscript?.finalizedText == "hello world trailing")
    }

    @Test("transcription failure does not stop recording (SPEC FR-2)")
    func transcriptionFailureKeepsRecording() async throws {
        let repository = InMemoryRepository()
        let engine = FakeTranscriptionEngine(behavior: .failAfter([
            .finalized(text: "partial", timeRange: TimeRange(start: 0, end: 1), confidence: nil),
        ]))
        let (deps, _) = makeDependencies(repository: repository, engine: engine)
        let session = RecordingSession(title: "Test", dependencies: deps)
        let collector = Task { () -> [RecordingSessionEvent] in
            var collected: [RecordingSessionEvent] = []
            for await event in session.events { collected.append(event) }
            return collected
        }

        try await session.start()
        let finished = try await session.stop()
        #expect(finished.recordingState == .completed)

        let segments = try await repository.segments(forRecording: session.recordingID)
        #expect(segments.map(\.text) == ["partial"])

        let statuses = await collector.value.compactMap { event -> LiveTranscriptionStatus? in
            if case let .transcription(s) = event { return s }
            return nil
        }
        #expect(statuses.contains { if case .failed = $0 { return true } else { return false } })
    }

    @Test("an unsupported engine is reported and the recording completes")
    func unsupportedEngine() async throws {
        let repository = InMemoryRepository()
        let (deps, _) = makeDependencies(repository: repository, engine: FakeTranscriptionEngine(behavior: .unsupported))
        let session = RecordingSession(title: "Test", dependencies: deps)
        let collector = Task { () -> [RecordingSessionEvent] in
            var collected: [RecordingSessionEvent] = []
            for await event in session.events { collected.append(event) }
            return collected
        }
        try await session.start()
        let finished = try await session.stop()
        #expect(finished.recordingState == .completed)
        let events = await collector.value
        #expect(events.contains(.transcription(.unavailable(reason: "fake unsupported"))))
    }

    @Test("no engine configured still records")
    func noEngine() async throws {
        let repository = InMemoryRepository()
        let (deps, _) = makeDependencies(repository: repository, engine: nil)
        let session = RecordingSession(title: "Test", dependencies: deps)
        try await session.start()
        let finished = try await session.stop()
        #expect(finished.recordingState == .completed)
        #expect(try await repository.segments(forRecording: session.recordingID).isEmpty)
    }

    @Test("capture start failure marks the recording interrupted and throws")
    func captureStartFailure() async throws {
        let repository = InMemoryRepository()
        let (deps, _) = makeDependencies(repository: repository, engine: nil, failStart: true)
        let session = RecordingSession(title: "Test", dependencies: deps)
        await #expect(throws: AudioCaptureError.inputUnavailable) {
            try await session.start()
        }
        let saved = try #require(await repository.recording(id: session.recordingID))
        #expect(saved.recordingState == .interrupted)
        #expect(await session.currentState == .failed(reason: AudioCaptureError.inputUnavailable.localizedDescription))
    }

    @Test("stop before start is rejected")
    func stopBeforeStart() async throws {
        let repository = InMemoryRepository()
        let (deps, _) = makeDependencies(repository: repository, engine: nil)
        let session = RecordingSession(title: "Test", dependencies: deps)
        await #expect(throws: RecordingSessionError.self) {
            _ = try await session.stop()
        }
    }
}
