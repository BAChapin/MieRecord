import ConversationPipeline
import Foundation
import Observation
import UIKit

/// App-wide tracker for re-transcription jobs.
///
/// Jobs live here rather than in a screen's view model so leaving the
/// recording screen does not cancel them, and so the list can show progress.
/// Each job holds a UIKit background-task assertion, which asks iOS for extra
/// time if the app is backgrounded; if that time expires the job is cancelled
/// and the previous transcript is kept.
@Observable
final class TranscriptionJobs {
    /// Progress in [0, 1] for each running job.
    private(set) var progress: [UUID: Double] = [:]
    /// Last error per recording, cleared when a new job starts.
    private(set) var errors: [UUID: String] = [:]
    /// Incremented whenever a job finishes, so screens know to reload.
    private(set) var revision = 0

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let service: RetranscriptionService

    init(service: RetranscriptionService) {
        self.service = service
    }

    func isRunning(_ recordingID: UUID) -> Bool {
        tasks[recordingID] != nil
    }

    func start(_ recordingID: UUID) {
        guard tasks[recordingID] == nil else { return }
        errors[recordingID] = nil
        progress[recordingID] = 0

        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Re-transcribe recording") { [weak self] in
            self?.cancel(recordingID)
        }
        let service = service
        // Called from the engine's task; hops to the main actor to publish.
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in
                self?.updateProgress(fraction, for: recordingID)
            }
        }
        tasks[recordingID] = Task { [weak self] in
            do {
                try await service.retranscribe(recordingID: recordingID, progress: report)
            } catch is CancellationError {
                // Previous transcript kept; nothing to report.
            } catch {
                self?.errors[recordingID] = error.localizedDescription
            }
            self?.finish(recordingID)
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
    }

    func cancel(_ recordingID: UUID) {
        tasks[recordingID]?.cancel()
    }

    func clearError(_ recordingID: UUID) {
        errors[recordingID] = nil
    }

    private func updateProgress(_ fraction: Double, for recordingID: UUID) {
        // Ignore late updates that arrive after the job finished.
        guard tasks[recordingID] != nil else { return }
        progress[recordingID] = fraction
    }

    private func finish(_ recordingID: UUID) {
        tasks[recordingID] = nil
        progress[recordingID] = nil
        revision += 1
    }
}
