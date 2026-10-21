import ConversationAudio
import ConversationCore
import ConversationDiarization
import ConversationML
import ConversationPipeline
import ConversationStorage
import Foundation
import Observation
import SwiftData

/// Composition root. Builds the storage, audio, and ML implementations once and
/// hands them to view models, so engines can be swapped here without touching
/// views or the domain model.
@Observable
final class AppDependencies {
    let repository: any RecordingRepository
    let audioFileStore: any AudioFileStore
    let transcriptionEngine: (any StreamingTranscriptionEngine)?
    let processingJobs: ProcessingJobs
    let speakerEditor: SpeakerEditor
    let identity: IdentityService
    /// Non-nil when persistent storage could not be opened; the app then runs
    /// on an in-memory store so recording still works for the session.
    let startupError: String?

    init(
        repository: any RecordingRepository,
        identityRepository: any SpeakerIdentityRepository,
        audioFileStore: any AudioFileStore,
        transcriptionEngine: (any StreamingTranscriptionEngine)?,
        fileTranscriptionEngine: any FileTranscriptionEngine,
        diarizationEngine: (any SpeakerDiarizationEngine)?,
        startupError: String? = nil
    ) {
        self.repository = repository
        self.audioFileStore = audioFileStore
        self.transcriptionEngine = transcriptionEngine
        // One retranscription service is shared so a recording can never be
        // re-transcribed twice at once, whichever path starts it.
        let retranscription = RetranscriptionService(
            repository: repository,
            audioFileStore: audioFileStore,
            engine: fileTranscriptionEngine
        )
        // Profiles are only comparable with voiceprints from the same engine.
        let identity = IdentityService(
            recordings: repository,
            identity: identityRepository,
            currentEngine: diarizationEngine?.descriptor
        )
        self.identity = identity
        self.processingJobs = ProcessingJobs(
            retranscription: retranscription,
            postProcessing: PostProcessingCoordinator(
                repository: repository,
                audioFileStore: audioFileStore,
                retranscription: retranscription,
                diarizer: diarizationEngine,
                identityRepository: identityRepository,
                identity: identity
            )
        )
        self.speakerEditor = SpeakerEditor(repository: repository, identity: identityRepository)
        self.startupError = startupError
    }

    static func live() -> AppDependencies {
        var startupError: String?
        let container: ModelContainer
        do {
            // SwiftData places the store in Application Support but logs errors
            // when the directory does not exist yet; create it first.
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            container = try ConversationStorage.makeModelContainer()
        } catch {
            startupError = "Persistent storage is unavailable (\(error.localizedDescription)). Recordings made now will not be kept."
            // An in-memory container cannot fail for a valid schema.
            // swiftlint:disable:next force_try
            container = try! ConversationStorage.makeModelContainer(inMemory: true)
        }

        let audioFileStore: any AudioFileStore
        do {
            audioFileStore = try DirectoryAudioFileStore.applicationSupport()
        } catch {
            startupError = (startupError.map { $0 + " " } ?? "") + "Could not create the recordings folder: \(error.localizedDescription)"
            audioFileStore = DirectoryAudioFileStore(directoryURL: FileManager.default.temporaryDirectory.appending(path: "Recordings"))
        }

        // One Apple engine serves both live and whole-file transcription.
        let speechEngine = AppleSpeechTranscriptionEngine(locale: .current)
        let store = SwiftDataRecordingRepository(modelContainer: container)
        return AppDependencies(
            repository: store,
            identityRepository: store,
            audioFileStore: audioFileStore,
            transcriptionEngine: speechEngine,
            fileTranscriptionEngine: speechEngine,
            // Models ship in the app bundle; the engine never downloads them.
            diarizationEngine: FluidAudioDiarizationEngine(
                modelsDirectory: Bundle.main.url(forResource: "DiarizationModels", withExtension: nil)
            ),
            startupError: startupError
        )
    }

    func makeRecordingSession(title: String) -> RecordingSession {
        RecordingSession(
            title: title,
            dependencies: RecordingSessionDependencies(
                repository: repository,
                audioFileStore: audioFileStore,
                transcriptionEngine: transcriptionEngine,
                makeCaptureSource: { url in AudioCaptureSession(fileURL: url) }
            )
        )
    }

    /// Marks recordings orphaned by a previous crash as interrupted.
    func recoverInterruptedRecordings() async {
        _ = try? await RecordingRecovery.repairInterruptedRecordings(repository: repository, audioFileStore: audioFileStore)
        _ = try? await RecordingRecovery.repairInterruptedProcessing(repository: repository)
    }

    func deleteRecording(_ recording: Recording) async throws {
        processingJobs.cancel(recording.id)
        try await repository.deleteRecording(id: recording.id)
        try audioFileStore.removeFile(for: recording.audioFile)
    }
}
