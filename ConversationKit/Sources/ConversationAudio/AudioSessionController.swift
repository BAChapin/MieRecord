import AVFoundation

#if os(iOS)
/// Configures the shared `AVAudioSession` for conversation capture.
///
/// Category `.playAndRecord` is used so the app can later play back recordings
/// without reconfiguring, and so Bluetooth headsets work for capture.
public enum AudioSessionController {
    public static func activateForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true)
    }

    public static func activateForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
    }

    public static func deactivate() {
        // Deactivation failures are non-fatal; the session is reconfigured on
        // the next activation anyway.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
