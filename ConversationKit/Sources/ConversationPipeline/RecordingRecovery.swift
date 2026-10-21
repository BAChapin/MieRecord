import AVFoundation
import ConversationCore
import Foundation

/// Repairs recordings left in `.recording` state by a crash or termination.
///
/// The audio file is the source of truth: its length becomes the recording's
/// duration and the state becomes `.interrupted`, so the recording stays
/// visible and playable (SPEC FR-1 durability).
public enum RecordingRecovery {
    @discardableResult
    public static func repairInterruptedRecordings(
        repository: any RecordingRepository,
        audioFileStore: any AudioFileStore
    ) async throws -> [Recording] {
        var repaired: [Recording] = []
        for var recording in try await repository.allRecordings() where recording.recordingState == .recording {
            let url = audioFileStore.url(for: recording.audioFile)
            if let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 {
                recording.duration = Double(file.length) / file.fileFormat.sampleRate
                recording.audioFile.sampleRate = file.fileFormat.sampleRate
                recording.audioFile.channelCount = Int(file.fileFormat.channelCount)
            }
            recording.recordingState = .interrupted
            try await repository.save(recording)
            repaired.append(recording)
        }
        return repaired
    }

    /// Marks recordings whose processing was cut off (app terminated mid-job)
    /// as failed, so the UI offers a retry instead of showing a stuck spinner.
    /// Processing never replaces data until it succeeds, so the previous
    /// transcript is still intact.
    @discardableResult
    public static func repairInterruptedProcessing(repository: any RecordingRepository) async throws -> [UUID] {
        var repaired: [UUID] = []
        for recording in try await repository.allRecordings() {
            guard case let .processing(stage) = recording.processingState else { continue }
            try await repository.updateRecording(id: recording.id) {
                $0.processingState = .failed(ProcessingFailure(
                    stage: stage,
                    message: "Processing was interrupted before it finished. The previous transcript was kept."
                ))
            }
            repaired.append(recording.id)
        }
        return repaired
    }
}
