import ConversationCore
import Foundation
import Observation

@Observable
final class RecordingDetailViewModel {
    private(set) var recording: Recording
    private(set) var segments: [TranscriptSegment] = []
    var errorMessage: String?
    let playback = AudioPlaybackController()

    private let dependencies: AppDependencies

    init(recording: Recording, dependencies: AppDependencies) {
        self.recording = recording
        self.dependencies = dependencies
    }

    var audioURL: URL { dependencies.audioFileStore.url(for: recording.audioFile) }

    var jobs: TranscriptionJobs { dependencies.transcriptionJobs }
    var isRetranscribing: Bool { jobs.isRunning(recording.id) }
    var retranscriptionProgress: Double? { jobs.progress[recording.id] }

    /// The most relevant re-transcription failure: this session's error, or a
    /// failure persisted from an earlier launch.
    var retranscriptionError: String? {
        if let error = jobs.errors[recording.id] { return error }
        if case let .failed(failure) = recording.processingState, failure.stage == .transcriptionFinalization {
            return failure.message
        }
        return nil
    }

    func load() async {
        playback.load(url: audioURL)
        await reloadTranscript()
    }

    /// Reloads the recording and transcript without touching playback.
    func reloadTranscript() async {
        do {
            if let latest = try await dependencies.repository.recording(id: recording.id) {
                recording = latest
            }
            segments = try await dependencies.repository.segments(forRecording: recording.id)
        } catch {
            errorMessage = "Could not load the transcript: \(error.localizedDescription)"
        }
    }

    func retranscribe() {
        jobs.start(recording.id)
    }

    func cancelRetranscription() {
        jobs.cancel(recording.id)
    }

    func rename(to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != recording.title else { return }
        do {
            // Atomic update so a concurrent re-transcription's state isn't
            // overwritten by this screen's possibly stale copy.
            recording = try await dependencies.repository.updateRecording(id: recording.id) { $0.title = trimmed }
        } catch {
            errorMessage = "Could not rename: \(error.localizedDescription)"
        }
    }

    /// The segment under the playhead, if any.
    var currentSegmentID: UUID? {
        let time = playback.currentTime
        return segments.first { $0.timeRange?.contains(time) == true }?.id
    }

    func unload() {
        playback.unload()
    }
}
