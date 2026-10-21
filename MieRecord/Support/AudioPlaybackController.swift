import AVFoundation
import ConversationAudio
import Foundation
import Observation

/// Plays back a recording file and publishes the playhead for transcript
/// highlighting. Lives on the main actor; `AVAudioPlayer` is lightweight enough
/// that no background work is needed.
@Observable
final class AudioPlaybackController {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?

    private var player: AVAudioPlayer?
    private var tickTask: Task<Void, Never>?

    func load(url: URL) {
        stopTicking()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            currentTime = 0
            errorMessage = nil
        } catch {
            player = nil
            errorMessage = "This recording cannot be played: \(error.localizedDescription)"
        }
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        #if os(iOS)
        try? AudioSessionController.activateForPlayback()
        #endif
        if player.currentTime >= player.duration - 0.05 {
            player.currentTime = 0
        }
        player.play()
        isPlaying = true
        startTicking()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicking()
        currentTime = player?.currentTime ?? 0
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), max(0, player.duration - 0.01))
        currentTime = player.currentTime
    }

    /// Seeks and starts playing from `time`.
    func play(from time: TimeInterval) {
        seek(to: time)
        play()
    }

    func unload() {
        pause()
        player = nil
        duration = 0
        currentTime = 0
    }

    private func startTicking() {
        stopTicking()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    return
                }
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}
