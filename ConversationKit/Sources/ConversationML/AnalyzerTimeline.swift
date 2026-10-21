import AVFoundation
import CoreMedia
import Foundation

/// Assigns `SpeechAnalyzer` input timestamps in the analyzer's own sample clock.
///
/// Why this exists: `AVAudioConverter` does not return a buffer's worth of output
/// per call when it resamples. With 48 kHz → 16 kHz it holds some samples back
/// and later emits them in a burst (observed: 1365, 1365, 1366, 1365, 1365,
/// 2774, … frames for 4800-frame inputs). Stamping each converted buffer with
/// the *input* chunk's start time therefore produces ranges that drift from the
/// audio they contain and eventually overlap, which `SpeechAnalyzer` rejects
/// with "Audio input timestamp overlaps or precedes prior audio input"
/// (SFSpeechErrorDomain 17) and stops transcribing.
///
/// Instead, each output buffer starts exactly where the previous one ended. The
/// clock only jumps forward when the capture side reports a real gap (chunks
/// dropped by a stalled consumer), so timestamps stay aligned with the file
/// timeline and are strictly non-overlapping by construction.
struct AnalyzerTimeline {
    let sampleRate: Double
    /// A chunk that starts later than this past the clock is treated as a gap.
    /// Must exceed converter latency (≈15 ms observed) to avoid false jumps.
    let gapToleranceSamples: Int64
    private(set) var nextSample: Int64 = 0

    init(sampleRate: Double, gapTolerance: TimeInterval = 0.05) {
        self.sampleRate = sampleRate
        self.gapToleranceSamples = Int64((gapTolerance * sampleRate).rounded())
    }

    /// Call for every incoming chunk before converting it.
    mutating func noteInputChunk(startingAt seconds: TimeInterval) {
        let expected = Int64((seconds * sampleRate).rounded())
        if expected > nextSample + gapToleranceSamples {
            // Audio was dropped upstream. Samples still held inside the converter
            // from before the gap will be stamped after it (≈15 ms error),
            // which is acceptable for transcript timing.
            nextSample = expected
        }
    }

    /// Returns the start time for an output buffer and advances the clock.
    mutating func stamp(frameCount: AVAudioFrameCount) -> CMTime {
        let start = CMTime(value: nextSample, timescale: CMTimeScale(sampleRate))
        nextSample += Int64(frameCount)
        return start
    }
}
