import ConversationCore
import ConversationML
import FluidAudio
import Foundation

/// `SpeakerDiarizationEngine` backed by FluidAudio's offline Core ML pipeline
/// (pyannote Community-1 segmentation, WeSpeaker embeddings, PLDA + VBx
/// clustering).
///
/// Offline guarantee: models are loaded only from `modelsDirectory`, which the
/// app ships in its bundle, and FluidAudio's Hugging Face downloader is put in
/// offline mode before any loader runs, so a missing or damaged model raises an
/// error instead of touching the network. No audio leaves the device.
///
/// Concurrency: `OfflineDiarizerManager` is not `Sendable`, so a fresh manager
/// is created per run as a local value. Only the `Sendable` loaded models are
/// cached on the actor.
public actor FluidAudioDiarizationEngine: SpeakerDiarizationEngine {
    /// Hugging Face revision of `FluidInference/speaker-diarization-coreml`
    /// that FluidAudio 0.17.7 pins and that the bundled models were fetched at.
    public static let modelRevision = "df2625ac79a7ac6b65ad868fee6d80f320da4232"
    /// Folder FluidAudio expects inside the models directory.
    static let repoFolder = "speaker-diarization"
    static let requiredFiles = [
        "Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc",
        "plda-parameters.json", ".fluidaudio-revision",
    ]

    public nonisolated let descriptor = EngineDescriptor(
        identifier: "fluidaudio.offline-diarizer",
        version: "0.17.7+\(String(modelRevision.prefix(8)))"
    )

    private let modelsDirectory: URL?
    private let configuration: OfflineDiarizerConfig
    private var models: OfflineDiarizerModels?

    /// - Parameter modelsDirectory: directory containing `speaker-diarization/`.
    ///   `nil` (for example, a build without bundled models) makes the engine
    ///   report itself unsupported.
    public init(modelsDirectory: URL?, configuration: OfflineDiarizerConfig = .default) {
        self.modelsDirectory = modelsDirectory
        var configuration = configuration
        // Per-window 256-d embeddings (with cluster assignment) feed identity
        // matching. The per-segment `embedding` FluidAudio also returns is the
        // cluster centroid repeated, so it cannot reveal mixed clusters.
        configuration.exposeChunkEmbeddings = true
        self.configuration = configuration
    }

    public func availability() async -> EngineAvailability {
        if let reason = Self.missingModelsReason(in: modelsDirectory) {
            return .unsupported(reason: reason)
        }
        return .available
    }

    /// Nothing to install: models ship with the app and are never downloaded.
    public func prepare() async throws {
        if let reason = Self.missingModelsReason(in: modelsDirectory) {
            throw DiarizationError.modelUnavailable(reason)
        }
    }

    public func diarize(
        audioURL: URL,
        recordingID: UUID,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DiarizationOutput {
        let models = try await loadedModels()
        try Task.checkCancellation()

        let manager = OfflineDiarizerManager(config: configuration)
        manager.initialize(models: models)
        let result: DiarizationResult
        do {
            result = try await manager.process(audioURL) { done, total in
                guard total > 0 else { return }
                progress(Double(done) / Double(total))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DiarizationError.engineFailure("Speaker detection failed: \(error.localizedDescription)")
        }
        return Self.output(
            segments: result.segments.map {
                (speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
            },
            windows: (result.chunkEmbeddings ?? []).map {
                (speaker: $0.speakerId, start: $0.startTimeSeconds, end: $0.endTimeSeconds, vector: $0.embedding256)
            },
            recordingID: recordingID,
            engine: descriptor
        )
    }

    /// Builds the timeline and attaches window embeddings to the same clusters.
    /// Windows for speakers with no turns, or with non-finite values, are dropped.
    static func output(
        segments: [(speaker: String, start: Double, end: Double)],
        windows: [(speaker: String, start: Double, end: Double, vector: [Float])],
        recordingID: UUID,
        engine: EngineDescriptor
    ) -> DiarizationOutput {
        let (timeline, clusterIDs) = timelineAndIDs(from: segments, recordingID: recordingID)
        let embeddings = windows.compactMap { window -> WindowEmbedding? in
            guard
                let clusterID = clusterIDs[window.speaker],
                !window.vector.isEmpty,
                window.vector.allSatisfy(\.isFinite)
            else { return nil }
            return WindowEmbedding(clusterID: clusterID, timeRange: TimeRange(start: window.start, end: window.end), vector: window.vector)
        }
        return DiarizationOutput(
            timeline: timeline,
            voiceData: embeddings.isEmpty ? nil : RecordingVoiceData(engine: engine, windows: embeddings)
        )
    }

    // MARK: - Mapping

    /// Maps engine speaker IDs ("S1", "S2", …) to fresh recording-local
    /// cluster UUIDs. Engine IDs are never persisted.
    static func timeline(
        from segments: [(speaker: String, start: Double, end: Double)],
        recordingID: UUID
    ) -> SpeakerTimeline {
        timelineAndIDs(from: segments, recordingID: recordingID).timeline
    }

    static func timelineAndIDs(
        from segments: [(speaker: String, start: Double, end: Double)],
        recordingID: UUID
    ) -> (timeline: SpeakerTimeline, clusterIDs: [String: UUID]) {
        var clusterIDs: [String: UUID] = [:]
        var turns: [SpeakerTurn] = []
        for segment in segments where segment.end > segment.start {
            let clusterID = clusterIDs[segment.speaker] ?? {
                let id = UUID()
                clusterIDs[segment.speaker] = id
                return id
            }()
            turns.append(SpeakerTurn(
                recordingID: recordingID,
                clusterID: clusterID,
                timeRange: TimeRange(start: segment.start, end: segment.end)
            ))
        }
        let clusters = clusterIDs.values.map { SpeakerCluster(id: $0, recordingID: recordingID, firstAppearance: 0) }
        // `normalized()` computes first appearances and orders everything.
        let timeline = SpeakerTimeline(clusters: clusters, turns: turns).normalized()
        let kept = Set(timeline.clusters.map(\.id))
        return (timeline, clusterIDs.filter { kept.contains($0.value) })
    }

    // MARK: - Models

    private func loadedModels() async throws -> OfflineDiarizerModels {
        if let models { return models }
        if let reason = Self.missingModelsReason(in: modelsDirectory) {
            throw DiarizationError.modelUnavailable(reason)
        }
        // Must be set before any FluidAudio loader runs.
        ModelHub.offlineMode = true
        do {
            let loaded = try await OfflineDiarizerModels.load(from: modelsDirectory)
            models = loaded
            return loaded
        } catch {
            throw DiarizationError.modelUnavailable(error.localizedDescription)
        }
    }

    static func missingModelsReason(in directory: URL?) -> String? {
        guard let directory else { return "Speaker models are not included in this build." }
        let repo = directory.appending(path: repoFolder, directoryHint: .isDirectory)
        let missing = requiredFiles.filter { !FileManager.default.fileExists(atPath: repo.appending(path: $0).path) }
        return missing.isEmpty ? nil : "Speaker model files are missing: \(missing.joined(separator: ", "))."
    }
}
