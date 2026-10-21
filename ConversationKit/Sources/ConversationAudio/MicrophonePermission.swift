import AVFoundation

/// Thin wrapper over `AVAudioApplication` record permission.
public enum MicrophonePermission {
    public enum Status: Sendable, Equatable {
        case undetermined
        case denied
        case granted
    }

    public static var current: Status {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .undetermined
        @unknown default: .denied
        }
    }

    /// Prompts if undetermined; otherwise returns the stored decision.
    public static func request() async -> Status {
        switch current {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            return granted ? .granted : .denied
        }
    }
}
