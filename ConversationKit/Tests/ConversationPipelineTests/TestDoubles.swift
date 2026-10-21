import AVFoundation
import ConversationAudio
import ConversationCore
import ConversationML
import Foundation

/// In-memory repository used to observe what the session persists.
actor InMemoryRepository: RecordingRepository, SpeakerIdentityRepository {
    var recordings: [UUID: Recording] = [:]
    var segmentsByRecording: [UUID: [TranscriptSegment]] = [:]
    var timelines: [UUID: SpeakerTimeline] = [:]
    var voice: [UUID: RecordingVoiceData] = [:]
    var attributions: [UUID: [SpeakerAttribution]] = [:]
    var profiles: [UUID: SpeakerProfile] = [:]
    var samples: [UUID: VoiceSample] = [:]
    var feedback: [IdentityFeedback] = []
    var saveCount = 0

    func allRecordings() async throws -> [Recording] { Array(recordings.values) }
    func recording(id: UUID) async throws -> Recording? { recordings[id] }
    func save(_ recording: Recording) async throws {
        recordings[recording.id] = recording
        saveCount += 1
    }
    @discardableResult
    func updateRecording(id: UUID, _ transform: @Sendable (inout Recording) -> Void) async throws -> Recording {
        guard var recording = recordings[id] else { throw StorageError.recordingNotFound(id) }
        transform(&recording)
        recordings[id] = recording
        saveCount += 1
        return recording
    }
    func deleteRecording(id: UUID) async throws {
        recordings[id] = nil
        segmentsByRecording[id] = nil
        timelines[id] = nil
        voice[id] = nil
        attributions[id] = nil
    }

    // SpeakerIdentityRepository
    func voiceData(forRecording recordingID: UUID) async throws -> RecordingVoiceData? { voice[recordingID] }
    func replaceVoiceData(_ data: RecordingVoiceData?, forRecording recordingID: UUID) async throws { voice[recordingID] = data }
    func speakerAttributions(forRecording recordingID: UUID) async throws -> [SpeakerAttribution] { attributions[recordingID] ?? [] }
    func replaceSpeakerAttributions(_ list: [SpeakerAttribution], forRecording recordingID: UUID) async throws { attributions[recordingID] = list }
    func speakerProfiles() async throws -> [SpeakerProfile] { profiles.values.sorted { $0.displayName < $1.displayName } }
    func saveSpeakerProfile(_ profile: SpeakerProfile) async throws { profiles[profile.id] = profile }
    func deleteSpeakerProfile(id: UUID) async throws {
        profiles[id] = nil
        samples = samples.filter { $0.value.profileID != id }
        feedback.removeAll { $0.profileID == id }
    }
    func voiceSamples(forProfile profileID: UUID?) async throws -> [VoiceSample] {
        samples.values.filter { profileID == nil || $0.profileID == profileID }.sorted { $0.createdAt < $1.createdAt }
    }
    func saveVoiceSample(_ sample: VoiceSample) async throws { samples[sample.id] = sample }
    func deleteVoiceSample(id: UUID) async throws { samples[id] = nil }
    func saveIdentityFeedback(_ item: IdentityFeedback) async throws { feedback.append(item) }
    func identityFeedback() async throws -> [IdentityFeedback] { feedback }
    func segments(forRecording recordingID: UUID) async throws -> [TranscriptSegment] {
        segmentsByRecording[recordingID] ?? []
    }
    func saveSegments(_ segments: [TranscriptSegment]) async throws {
        for segment in segments {
            var list = segmentsByRecording[segment.recordingID] ?? []
            if let index = list.firstIndex(where: { $0.id == segment.id }) {
                list[index] = segment
            } else {
                list.append(segment)
            }
            segmentsByRecording[segment.recordingID] = list
        }
    }
    func replaceSegments(_ segments: [TranscriptSegment], forRecording recordingID: UUID) async throws {
        segmentsByRecording[recordingID] = segments
    }
    func speakerTimeline(forRecording recordingID: UUID) async throws -> SpeakerTimeline {
        timelines[recordingID] ?? .empty
    }
    func replaceSpeakerTimeline(_ timeline: SpeakerTimeline, forRecording recordingID: UUID) async throws {
        timelines[recordingID] = timeline
    }
}

/// Scripted diarizer. Clusters are keyed by a small integer so tests can
/// describe turns compactly: `[(0, 0, 5), (1, 5, 9)]`.
final class FakeDiarizer: SpeakerDiarizationEngine, @unchecked Sendable {
    enum Behavior: Sendable {
        case turns([(speaker: Int, start: Double, end: Double)])
        /// Turns plus a voice vector per engine speaker index; one window is
        /// emitted per turn with that vector.
        case voices([(speaker: Int, start: Double, end: Double)], vectors: [Int: [Float]])
        case fail
        case unsupported
    }

    let descriptor: EngineDescriptor
    let behavior: Behavior
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    init(_ behavior: Behavior, version: String = "1") {
        self.behavior = behavior
        self.descriptor = EngineDescriptor(identifier: "test.diarizer", version: version)
    }

    func availability() async -> EngineAvailability {
        if case .unsupported = behavior { return .unsupported(reason: "fake diarizer unsupported") }
        return .available
    }

    func prepare() async throws {}

    func diarize(audioURL: URL, recordingID: UUID, progress: @escaping @Sendable (Double) -> Void) async throws -> DiarizationOutput {
        lock.withLock { _calls += 1 }
        let spec: [(speaker: Int, start: Double, end: Double)]
        var vectors: [Int: [Float]] = [:]
        switch behavior {
        case .fail:
            throw DiarizationError.engineFailure("fake diarizer failed")
        case .unsupported:
            return DiarizationOutput(timeline: .empty)
        case let .turns(turns):
            spec = turns
        case let .voices(turns, voiceVectors):
            spec = turns
            vectors = voiceVectors
        }
        var ids: [Int: UUID] = [:]
        for entry in spec where ids[entry.speaker] == nil { ids[entry.speaker] = UUID() }
        progress(1)
        let timeline = SpeakerTimeline(
            // Engine-chosen recording IDs are deliberately wrong; the
            // coordinator must re-own them.
            clusters: ids.values.map { SpeakerCluster(id: $0, recordingID: UUID(), firstAppearance: 0) },
            turns: spec.map { SpeakerTurn(recordingID: UUID(), clusterID: ids[$0.speaker]!, timeRange: TimeRange(start: $0.start, end: $0.end)) }
        )
        let windows = spec.compactMap { entry -> WindowEmbedding? in
            vectors[entry.speaker].map { WindowEmbedding(clusterID: ids[entry.speaker]!, timeRange: TimeRange(start: entry.start, end: entry.end), vector: $0) }
        }
        return DiarizationOutput(timeline: timeline, voiceData: windows.isEmpty ? nil : RecordingVoiceData(engine: descriptor, windows: windows))
    }
}

extension FakeDiarizer.Behavior: @unchecked Sendable {}

struct TemporaryAudioFileStore: AudioFileStore {
    let directory: URL
    init() {
        directory = FileManager.default.temporaryDirectory.appending(path: "ConversationKitTests-\(UUID().uuidString)")
    }
    func makeFileURL(forRecordingID id: UUID, fileExtension: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(id.uuidString).\(fileExtension)")
    }
    func url(for reference: AudioFileReference) -> URL { directory.appending(path: reference.fileName) }
    func removeFile(for reference: AudioFileReference) throws {
        try? FileManager.default.removeItem(at: url(for: reference))
    }
}

/// Scripted capture source: emits a few chunks and events, then reports a summary.
final class FakeCaptureSource: AudioCaptureSource, @unchecked Sendable {
    let chunks: AsyncStream<AudioChunk>
    let events: AsyncStream<AudioCaptureEvent>
    private let chunkContinuation: AsyncStream<AudioChunk>.Continuation
    private let eventContinuation: AsyncStream<AudioCaptureEvent>.Continuation
    let fileURL: URL
    let duration: TimeInterval
    let failStart: Bool

    init(fileURL: URL, duration: TimeInterval = 3, failStart: Bool = false) {
        self.fileURL = fileURL
        self.duration = duration
        self.failStart = failStart
        (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        (events, eventContinuation) = AsyncStream.makeStream(of: AudioCaptureEvent.self)
    }

    func start() async throws -> AudioStreamDescription {
        if failStart { throw AudioCaptureError.inputUnavailable }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        chunkContinuation.yield(AudioChunk(buffer: buffer, startTime: 0))
        chunkContinuation.yield(AudioChunk(buffer: buffer, startTime: 0.1))
        eventContinuation.yield(.started(sampleRate: 16_000, channelCount: 1))
        eventContinuation.yield(.progress(elapsed: 0.2))
        return AudioStreamDescription(sampleRate: 16_000, channelCount: 1)
    }

    func emit(_ event: AudioCaptureEvent) {
        eventContinuation.yield(event)
    }

    func stop() async throws -> AudioCaptureSummary {
        chunkContinuation.finish()
        eventContinuation.finish()
        return AudioCaptureSummary(fileURL: fileURL, duration: duration, sampleRate: 16_000, channelCount: 1)
    }
}

/// Scripted transcription engine.
struct FakeTranscriptionEngine: StreamingTranscriptionEngine {
    enum Behavior: Sendable {
        case script([TranscriptionEvent])
        case failAfter([TranscriptionEvent])
        case unsupported
    }

    let descriptor = EngineDescriptor(identifier: "test.engine", version: "1")
    let behavior: Behavior

    func availability() async -> TranscriptionAvailability {
        if case .unsupported = behavior { return .unsupported(reason: "fake unsupported") }
        return .available
    }

    func prepare() async throws {}

    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                // Drain audio like a real engine would, then emit the script.
                for await _ in audio {}
                switch behavior {
                case let .script(events):
                    events.forEach { continuation.yield($0) }
                    continuation.finish()
                case let .failAfter(events):
                    events.forEach { continuation.yield($0) }
                    continuation.finish(throwing: TranscriptionError.engineFailure("fake failure"))
                case .unsupported:
                    continuation.finish()
                }
            }
        }
    }
}

/// Scripted whole-file engine. `gate` lets a test hold a run open to exercise
/// concurrency and cancellation.
final class FakeFileTranscriptionEngine: FileTranscriptionEngine, @unchecked Sendable {
    enum Behavior: Sendable {
        case spans([TranscribedSpan])
        case fail(TranscriptionError)
        case unsupported
        /// Waits until cancelled.
        case hang
    }

    let fileDescriptor = EngineDescriptor(identifier: "test.file", version: "1")
    let behavior: Behavior
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    init(_ behavior: Behavior) { self.behavior = behavior }

    func availability() async -> TranscriptionAvailability {
        if case .unsupported = behavior { return .unsupported(reason: "fake unsupported") }
        return .available
    }

    func prepare() async throws {}

    func transcribeFile(at url: URL, progress: @escaping @Sendable (TimeInterval) -> Void) async throws -> [TranscribedSpan] {
        lock.withLock { _calls += 1 }
        switch behavior {
        case let .spans(spans):
            for span in spans { if let end = span.timeRange?.end { progress(end) } }
            return spans
        case let .fail(error):
            throw error
        case .unsupported:
            return []
        case .hang:
            while true {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}
