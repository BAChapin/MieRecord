import ConversationAudio
import ConversationCore
import ConversationML
import Foundation
import OSLog

/// Status of live transcription during a session. Independent of capture status.
public enum LiveTranscriptionStatus: Sendable, Equatable {
    case notConfigured
    case preparing
    case active
    /// The engine cannot run here; recording continues without live text.
    case unavailable(reason: String)
    /// The engine failed mid-session; recording continues without live text.
    case failed(reason: String)
    case finished
}

public enum RecordingSessionState: Sendable, Equatable {
    case idle
    case starting
    case recording
    case interrupted
    case stopping
    case finished
    case failed(reason: String)
}

public enum RecordingSessionEvent: Sendable, Equatable {
    case state(RecordingSessionState)
    case elapsed(TimeInterval)
    case transcript(LiveTranscript)
    case transcription(LiveTranscriptionStatus)
}

/// Everything a `RecordingSession` needs, injected so engines and storage can be
/// replaced (including by test doubles) without touching the session.
public struct RecordingSessionDependencies: Sendable {
    public var repository: any RecordingRepository
    public var audioFileStore: any AudioFileStore
    /// `nil` disables live transcription entirely.
    public var transcriptionEngine: (any StreamingTranscriptionEngine)?
    public var makeCaptureSource: @Sendable (URL) -> any AudioCaptureSource
    /// Upper bound on how long `stop()` waits for the engine to finalize.
    public var transcriptionFinalizationTimeout: Duration

    public init(
        repository: any RecordingRepository,
        audioFileStore: any AudioFileStore,
        transcriptionEngine: (any StreamingTranscriptionEngine)?,
        makeCaptureSource: @escaping @Sendable (URL) -> any AudioCaptureSource,
        transcriptionFinalizationTimeout: Duration = .seconds(15)
    ) {
        self.repository = repository
        self.audioFileStore = audioFileStore
        self.transcriptionEngine = transcriptionEngine
        self.makeCaptureSource = makeCaptureSource
        self.transcriptionFinalizationTimeout = transcriptionFinalizationTimeout
    }
}

public enum RecordingSessionError: Error, Sendable, Equatable {
    case invalidState(String)
}

/// Orchestrates one live recording: durable capture, optional live transcription,
/// incremental persistence, and finalization.
///
/// Durability rules (SPEC FR-1/FR-2):
/// - The `Recording` row is saved *before* capture starts, in state `.recording`,
///   so a crash leaves a visible, playable recording.
/// - Every finalized segment is persisted as soon as it arrives.
/// - Transcription failures are reported through `events` and never stop capture.
public actor RecordingSession {
    public let recordingID: UUID
    public nonisolated let events: AsyncStream<RecordingSessionEvent>

    private let eventContinuation: AsyncStream<RecordingSessionEvent>.Continuation
    private let dependencies: RecordingSessionDependencies
    private let title: String

    private var state: RecordingSessionState = .idle
    private var recording: Recording?
    private var capture: (any AudioCaptureSource)?
    private var assembler: LiveTranscriptAssembler?
    private var captureEventsTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionStatus: LiveTranscriptionStatus = .notConfigured

    public init(
        recordingID: UUID = UUID(),
        title: String,
        dependencies: RecordingSessionDependencies
    ) {
        self.recordingID = recordingID
        self.title = title
        self.dependencies = dependencies
        (events, eventContinuation) = AsyncStream.makeStream(of: RecordingSessionEvent.self)
    }

    public var currentState: RecordingSessionState { state }
    public var currentTranscript: LiveTranscript { assembler?.transcript ?? LiveTranscript() }

    // MARK: - Lifecycle

    public func start() async throws {
        guard state == .idle else { throw RecordingSessionError.invalidState("start() called in state \(state)") }
        setState(.starting)

        do {
            let fileURL = try dependencies.audioFileStore.makeFileURL(forRecordingID: recordingID, fileExtension: "caf")
            let source = dependencies.makeCaptureSource(fileURL)
            capture = source

            // Persist first so the recording is visible even if capture fails later.
            var recording = Recording(
                id: recordingID,
                title: title,
                audioFile: AudioFileReference(fileName: fileURL.lastPathComponent, sampleRate: 0, channelCount: 0),
                recordingState: .recording,
                liveTranscriptionEngine: dependencies.transcriptionEngine?.descriptor
            )
            try await dependencies.repository.save(recording)
            self.recording = recording

            let description = try await source.start()
            recording.audioFile.sampleRate = description.sampleRate
            recording.audioFile.channelCount = description.channelCount
            try await dependencies.repository.save(recording)
            self.recording = recording

            captureEventsTask = Task { [weak self] in
                for await event in source.events {
                    await self?.handleCaptureEvent(event)
                }
            }
            startTranscriptionIfPossible(source: source)
            setState(.recording)
        } catch {
            setState(.failed(reason: error.localizedDescription))
            await markInterrupted()
            throw error
        }
    }

    /// Stops capture, waits (bounded) for transcription to finalize, persists the
    /// final recording, and returns it.
    public func stop() async throws -> Recording {
        guard state == .recording || state == .interrupted, let capture, var recording else {
            throw RecordingSessionError.invalidState("stop() called in state \(state)")
        }
        setState(.stopping)

        let summary = try await capture.stop()
        captureEventsTask?.cancel()

        await waitForTranscriptionToFinish()

        if var assembler, let leftover = assembler.flushVolatile() {
            self.assembler = assembler
            try? await dependencies.repository.saveSegments([leftover])
            eventContinuation.yield(.transcript(assembler.transcript))
        }

        recording.duration = summary.duration
        recording.audioFile.sampleRate = summary.sampleRate
        recording.audioFile.channelCount = summary.channelCount
        recording.recordingState = .completed
        try await dependencies.repository.save(recording)
        self.recording = recording

        setState(.finished)
        eventContinuation.finish()
        return recording
    }

    // MARK: - Transcription

    private func startTranscriptionIfPossible(source: any AudioCaptureSource) {
        guard let engine = dependencies.transcriptionEngine else {
            setTranscriptionStatus(.notConfigured)
            return
        }
        assembler = LiveTranscriptAssembler(recordingID: recordingID, source: engine.descriptor)
        setTranscriptionStatus(.preparing)

        transcriptionTask = Task { [weak self] in
            switch await engine.availability() {
            case .available:
                break
            case .assetsRequired:
                do {
                    try await engine.prepare()
                } catch {
                    await self?.setTranscriptionStatus(.unavailable(reason: "Speech assets could not be installed: \(error.localizedDescription)"))
                    return
                }
            case let .unsupported(reason):
                await self?.setTranscriptionStatus(.unavailable(reason: reason))
                return
            }

            await self?.setTranscriptionStatus(.active)
            do {
                for try await event in engine.transcribe(source.chunks) {
                    await self?.handleTranscriptionEvent(event)
                }
                await self?.setTranscriptionStatus(.finished)
            } catch is CancellationError {
                await self?.setTranscriptionStatus(.finished)
            } catch {
                await self?.setTranscriptionStatus(.failed(reason: error.localizedDescription))
            }
        }
    }

    private func handleTranscriptionEvent(_ event: TranscriptionEvent) async {
        guard var assembler else { return }
        let newSegment = assembler.apply(event)
        self.assembler = assembler
        eventContinuation.yield(.transcript(assembler.transcript))
        if let newSegment {
            do {
                try await dependencies.repository.saveSegments([newSegment])
            } catch {
                // Persistence of one segment failing must not stop the session;
                // the final stop() pass re-saves the recording row.
                setTranscriptionStatus(.failed(reason: "Could not save transcript: \(error.localizedDescription)"))
            }
        }
    }

    private func waitForTranscriptionToFinish() async {
        guard let transcriptionTask else { return }
        let timeout = dependencies.transcriptionFinalizationTimeout
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await transcriptionTask.value; return true }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !finished {
            transcriptionTask.cancel()
            setTranscriptionStatus(.failed(reason: "Transcription did not finish in time; provisional text was kept."))
        }
    }

    // MARK: - Capture events

    private func handleCaptureEvent(_ event: AudioCaptureEvent) async {
        switch event {
        case .started, .configurationChanged:
            break
        case let .progress(elapsed):
            eventContinuation.yield(.elapsed(elapsed))
        case .interruptionBegan:
            if state == .recording { setState(.interrupted) }
        case let .interruptionEnded(resumed):
            if resumed, state == .interrupted { setState(.recording) }
        case let .failed(message):
            // Capture reported a write failure. Keep the session alive so the
            // user can stop and keep what was recorded; surface the failure.
            setState(.failed(reason: message))
            await markInterrupted()
        }
    }

    private func markInterrupted() async {
        guard var recording else { return }
        recording.recordingState = .interrupted
        try? await dependencies.repository.save(recording)
        self.recording = recording
    }

    // MARK: - State helpers

    private func setState(_ newState: RecordingSessionState) {
        state = newState
        eventContinuation.yield(.state(newState))
    }

    private static let logger = Logger(subsystem: "com.mietech.MieRecord", category: "RecordingSession")

    private func setTranscriptionStatus(_ status: LiveTranscriptionStatus) {
        switch status {
        case let .failed(reason):
            Self.logger.error("Live transcription failed for \(self.recordingID, privacy: .public): \(reason, privacy: .public)")
        case let .unavailable(reason):
            Self.logger.notice("Live transcription unavailable for \(self.recordingID, privacy: .public): \(reason, privacy: .public)")
        default:
            break
        }
        transcriptionStatus = status
        eventContinuation.yield(.transcription(status))
    }
}
