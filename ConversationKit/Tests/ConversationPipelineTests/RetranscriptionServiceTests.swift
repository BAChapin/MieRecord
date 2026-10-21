import ConversationCore
import ConversationML
import ConversationPipeline
import Foundation
import Testing

@Suite("Re-transcription")
struct RetranscriptionServiceTests {
    let store = TemporaryAudioFileStore()

    /// Saves a completed recording whose audio file exists, plus `segments`.
    private func seed(
        _ repository: InMemoryRepository,
        segments: [String] = ["old one", "old two"],
        edited: Bool = false,
        createFile: Bool = true,
        state: RecordingState = .completed
    ) async throws -> Recording {
        let id = UUID()
        let url = try store.makeFileURL(forRecordingID: id, fileExtension: "caf")
        if createFile { try Data([0]).write(to: url) }
        let recording = Recording(
            id: id,
            title: "T",
            duration: 10,
            audioFile: AudioFileReference(fileName: url.lastPathComponent, sampleRate: 48_000, channelCount: 1),
            recordingState: state
        )
        try await repository.save(recording)
        let source = EngineDescriptor(identifier: "live")
        try await repository.saveSegments(segments.enumerated().map { index, text in
            TranscriptSegment(
                recordingID: id,
                timeRange: TimeRange(start: Double(index), end: Double(index) + 1),
                text: text,
                isFinal: true,
                source: source,
                editedAt: edited ? Date() : nil
            )
        })
        return recording
    }

    private func service(_ repository: InMemoryRepository, _ engine: FakeFileTranscriptionEngine) -> RetranscriptionService {
        RetranscriptionService(repository: repository, audioFileStore: store, engine: engine)
    }

    private let newSpans = [
        TranscribedSpan(text: " This is a test. ", timeRange: TimeRange(start: 1.7, end: 3.4), confidence: 0.94),
        TranscribedSpan(text: "   ", timeRange: TimeRange(start: 4, end: 4.5), confidence: nil),
        TranscribedSpan(text: "How does this work?", timeRange: TimeRange(start: 5, end: 10), confidence: 0.99),
    ]

    @Test("replaces the transcript, tags the file engine, reports progress, and clears a prior failure")
    func success() async throws {
        let repository = InMemoryRepository()
        let recording = try await seed(repository)
        try await repository.updateRecording(id: recording.id) {
            $0.processingState = .failed(ProcessingFailure(stage: .transcriptionFinalization, message: "earlier"))
        }
        let progress = ProgressLog()

        let result = try await service(repository, FakeFileTranscriptionEngine(.spans(newSpans)))
            .retranscribe(recordingID: recording.id) { progress.append($0) }

        #expect(result.map(\.text) == ["This is a test.", "How does this work?"])
        let stored = try await repository.segments(forRecording: recording.id)
        #expect(stored.map(\.text) == ["This is a test.", "How does this work?"])
        #expect(stored.allSatisfy { $0.source.identifier == "test.file" && $0.isFinal })
        #expect(stored.first?.transcriptionConfidence == 0.94)
        #expect(try await repository.recording(id: recording.id)?.processingState == .notStarted)
        #expect(progress.values.last == 1)
        #expect(progress.values.contains { abs($0 - 0.34) < 1e-9 })
    }

    @Test("engine failure keeps the old transcript and records the failure")
    func failureKeepsTranscript() async throws {
        let repository = InMemoryRepository()
        let recording = try await seed(repository)
        await #expect(throws: TranscriptionError.engineFailure("boom")) {
            try await service(repository, FakeFileTranscriptionEngine(.fail(.engineFailure("boom"))))
                .retranscribe(recordingID: recording.id)
        }
        #expect(try await repository.segments(forRecording: recording.id).map(\.text) == ["old one", "old two"])
        guard case let .failed(failure) = try await repository.recording(id: recording.id)?.processingState else {
            Issue.record("expected failed state"); return
        }
        #expect(failure.stage == .transcriptionFinalization)
        #expect(failure.message == "boom")
    }

    @Test("an empty result never wipes an existing transcript")
    func emptyResultKeepsTranscript() async throws {
        let repository = InMemoryRepository()
        let recording = try await seed(repository)
        await #expect(throws: RetranscriptionError.noSpeechDetected) {
            try await service(repository, FakeFileTranscriptionEngine(.spans([])))
                .retranscribe(recordingID: recording.id)
        }
        #expect(try await repository.segments(forRecording: recording.id).count == 2)
    }

    @Test("an empty result is accepted when there was no transcript")
    func emptyResultWithoutTranscript() async throws {
        let repository = InMemoryRepository()
        let recording = try await seed(repository, segments: [])
        let result = try await service(repository, FakeFileTranscriptionEngine(.spans([])))
            .retranscribe(recordingID: recording.id)
        #expect(result.isEmpty)
        #expect(try await repository.recording(id: recording.id)?.processingState == .notStarted)
    }

    @Test("user edits are protected unless explicitly discarded (SPEC FR-6)")
    func userEdits() async throws {
        let repository = InMemoryRepository()
        let recording = try await seed(repository, edited: true)
        let engine = FakeFileTranscriptionEngine(.spans(newSpans))
        await #expect(throws: RetranscriptionError.wouldDiscardUserEdits(count: 2)) {
            try await service(repository, engine).retranscribe(recordingID: recording.id)
        }
        #expect(engine.calls == 0)
        #expect(try await repository.recording(id: recording.id)?.processingState == .notStarted)

        try await service(repository, engine).retranscribe(recordingID: recording.id, discardingUserEdits: true)
        #expect(try await repository.segments(forRecording: recording.id).count == 2)
        #expect(engine.calls == 1)
    }

    @Test("missing audio file fails without touching the transcript")
    func missingFile() async throws {
        let repository = InMemoryRepository()
        let recording = try await seed(repository, createFile: false)
        await #expect(throws: RetranscriptionError.audioFileMissing) {
            try await service(repository, FakeFileTranscriptionEngine(.spans(newSpans)))
                .retranscribe(recordingID: recording.id)
        }
        #expect(try await repository.segments(forRecording: recording.id).count == 2)
    }

    @Test("a recording still being captured is refused")
    func inProgress() async throws {
        let repository = InMemoryRepository()
        let recording = try await seed(repository, state: .recording)
        await #expect(throws: RetranscriptionError.recordingInProgress) {
            try await service(repository, FakeFileTranscriptionEngine(.spans(newSpans)))
                .retranscribe(recordingID: recording.id)
        }
    }

    @Test("an unsupported engine is reported as unavailable")
    func unsupported() async throws {
        let repository = InMemoryRepository()
        let recording = try await seed(repository)
        await #expect(throws: RetranscriptionError.engineUnavailable("fake unsupported")) {
            try await service(repository, FakeFileTranscriptionEngine(.unsupported))
                .retranscribe(recordingID: recording.id)
        }
    }

    @Test("a second run for the same recording is rejected while one is in flight; cancelling restores state")
    func concurrencyAndCancellation() async throws {
        let repository = InMemoryRepository()
        let recording = try await seed(repository)
        let service = service(repository, FakeFileTranscriptionEngine(.hang))

        let first = Task { try await service.retranscribe(recordingID: recording.id) }
        // Wait until the first run has marked the recording as processing.
        while try await repository.recording(id: recording.id)?.processingState != .processing(.transcriptionFinalization) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await service.isRunning(recordingID: recording.id))
        await #expect(throws: RetranscriptionError.alreadyRunning) {
            try await service.retranscribe(recordingID: recording.id)
        }

        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await repository.recording(id: recording.id)?.processingState == .notStarted)
        #expect(try await repository.segments(forRecording: recording.id).map(\.text) == ["old one", "old two"])
        #expect(await !service.isRunning(recordingID: recording.id))
    }

    @Test("launch recovery turns a stuck processing state into a retryable failure")
    func recovery() async throws {
        let repository = InMemoryRepository()
        let recording = try await seed(repository)
        try await repository.updateRecording(id: recording.id) { $0.processingState = .processing(.transcriptionFinalization) }
        let repaired = try await RecordingRecovery.repairInterruptedProcessing(repository: repository)
        #expect(repaired == [recording.id])
        guard case let .failed(failure) = try await repository.recording(id: recording.id)?.processingState else {
            Issue.record("expected failed state"); return
        }
        #expect(failure.stage == .transcriptionFinalization)
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []
    var values: [Double] { lock.withLock { _values } }
    func append(_ value: Double) { lock.withLock { _values.append(value) } }
}
