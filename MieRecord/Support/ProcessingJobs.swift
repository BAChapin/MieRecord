import ConversationCore
import ConversationPipeline
import Foundation
import Observation
import UIKit

/// App-wide runner for long jobs on saved recordings: re-transcription and
/// speaker identification. One job per recording at a time.
///
/// Jobs live here rather than in a screen's view model so leaving the screen
/// does not cancel them and the list can show their status. Each job holds a
/// UIKit background-task assertion, which asks iOS for extra time if the app is
/// backgrounded; if that time expires the job is cancelled and nothing already
/// saved is lost.
@Observable
final class ProcessingJobs {
    enum Kind: Equatable {
        case retranscribe
        case identifySpeakers
    }

    struct Status: Equatable {
        var kind: Kind
        var stage: ProcessingStage?
        /// Fraction of the current stage, when known.
        var fraction: Double?

        var description: String {
            switch stage {
            case .transcriptionFinalization?: kind == .retranscribe ? "Re-transcribing" : "Preparing transcript"
            case .diarization?: "Detecting speakers"
            case .alignment?: "Matching text to speakers"
            case .embeddingExtraction?, .identityMatching?, .persistence?, nil: kind == .retranscribe ? "Re-transcribing" : "Identifying speakers"
            }
        }
    }

    private(set) var status: [UUID: Status] = [:]
    /// Last error per recording, cleared when a new job starts.
    private(set) var errors: [UUID: String] = [:]
    /// The kind of the most recent job per recording, for "Try Again".
    private(set) var lastKind: [UUID: Kind] = [:]
    /// Incremented whenever stored data changes, so screens reload.
    private(set) var revision = 0

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let retranscription: RetranscriptionService
    private let postProcessing: PostProcessingCoordinator

    init(retranscription: RetranscriptionService, postProcessing: PostProcessingCoordinator) {
        self.retranscription = retranscription
        self.postProcessing = postProcessing
    }

    /// Whether this build includes a speaker detection engine at all.
    var canIdentifySpeakers: Bool { postProcessing.isDiarizationConfigured }

    func isRunning(_ recordingID: UUID) -> Bool {
        tasks[recordingID] != nil
    }

    func retranscribe(_ recordingID: UUID, discardingCorrections: Bool = false) {
        let retranscription = retranscription
        let postProcessing = postProcessing
        run(recordingID, kind: .retranscribe) { report in
            try await retranscription.retranscribe(recordingID: recordingID, discardingUserEdits: discardingCorrections) { fraction in
                report(ProcessingProgress(stage: .transcriptionFinalization, fraction: fraction))
            }
            // New text needs speakers again; reuses the stored speaker timeline.
            report(ProcessingProgress(stage: .alignment))
            try await postProcessing.realign(recordingID: recordingID)
        }
    }

    /// - Parameters:
    ///   - discardingCorrections: replace the user's speaker corrections.
    ///   - fresh: detect speakers again instead of reusing a stored result.
    func identifySpeakers(_ recordingID: UUID, discardingCorrections: Bool = false, fresh: Bool = false) {
        guard canIdentifySpeakers else { return }
        let postProcessing = postProcessing
        run(recordingID, kind: .identifySpeakers) { report in
            try await postProcessing.process(
                recordingID: recordingID,
                discardingSpeakerCorrections: discardingCorrections,
                reuseExistingDiarization: !fresh,
                progress: report
            )
        }
    }

    func cancel(_ recordingID: UUID) {
        tasks[recordingID]?.cancel()
    }

    /// Called after edits made outside a job (speaker corrections, renames).
    func noteDataChanged() {
        revision += 1
    }

    // MARK: - Private

    private func run(
        _ recordingID: UUID,
        kind: Kind,
        _ body: @escaping @Sendable (_ report: @escaping @Sendable (ProcessingProgress) -> Void) async throws -> Void
    ) {
        guard tasks[recordingID] == nil else { return }
        errors[recordingID] = nil
        lastKind[recordingID] = kind
        status[recordingID] = Status(kind: kind)

        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Process recording") { [weak self] in
            self?.cancel(recordingID)
        }
        // Called from engine tasks; hops to the main actor to publish.
        let report: @Sendable (ProcessingProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.update(progress, for: recordingID)
            }
        }
        tasks[recordingID] = Task { [weak self] in
            do {
                try await body(report)
            } catch is CancellationError {
                // Previous data kept; nothing to report.
            } catch {
                self?.errors[recordingID] = error.localizedDescription
            }
            self?.finish(recordingID)
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
    }

    private func update(_ progress: ProcessingProgress, for recordingID: UUID) {
        // Ignore late updates that arrive after the job finished.
        guard var current = status[recordingID], tasks[recordingID] != nil else { return }
        current.stage = progress.stage
        current.fraction = progress.fraction
        status[recordingID] = current
    }

    private func finish(_ recordingID: UUID) {
        tasks[recordingID] = nil
        status[recordingID] = nil
        revision += 1
    }
}
