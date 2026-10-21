import ConversationAudio
import ConversationCore
import ConversationPipeline
import Foundation
import Observation

/// Drives the live recording screen. Owns one `RecordingSession` and mirrors
/// its event stream into observable state for SwiftUI.
@Observable
final class RecordingViewModel {
    enum Phase: Equatable {
        case idle
        case requestingPermission
        case permissionDenied
        case starting
        case recording
        case interrupted
        case stopping
        case finished(Recording)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .recording, .interrupted: true
            default: false
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var transcript = LiveTranscript()
    private(set) var transcriptionStatus: LiveTranscriptionStatus = .notConfigured

    private let dependencies: AppDependencies
    private var session: RecordingSession?
    private var eventTask: Task<Void, Never>?

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    func start() async {
        guard phase == .idle else { return }
        phase = .requestingPermission
        guard await MicrophonePermission.request() == .granted else {
            phase = .permissionDenied
            return
        }

        phase = .starting
        let session = dependencies.makeRecordingSession(title: Formatters.defaultTitle())
        self.session = session
        eventTask = Task { [weak self] in
            for await event in session.events {
                self?.apply(event)
            }
        }
        do {
            try await session.start()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        guard let session, phase.isActive || isFailedButRecording else { return }
        phase = .stopping
        do {
            let recording = try await session.stop()
            phase = .finished(recording)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// A capture write failure moves the session to `.failed` while audio
    /// captured so far remains on disk; the user can still stop to keep it.
    private var isFailedButRecording: Bool {
        if case .failed = phase, session != nil { return true }
        return false
    }

    private func apply(_ event: RecordingSessionEvent) {
        switch event {
        case let .state(state):
            switch state {
            case .idle, .starting: break
            case .recording: phase = .recording
            case .interrupted: phase = .interrupted
            case .stopping: phase = .stopping
            case .finished: break // `stop()` sets `.finished(recording)`.
            case let .failed(reason): phase = .failed(reason)
            }
        case let .elapsed(seconds):
            elapsed = seconds
        case let .transcript(transcript):
            self.transcript = transcript
        case let .transcription(status):
            transcriptionStatus = status
        }
    }
}
