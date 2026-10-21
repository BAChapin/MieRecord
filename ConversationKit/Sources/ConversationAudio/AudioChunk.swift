import AVFoundation
import Foundation

/// A block of captured PCM audio positioned on the recording's file timeline.
///
/// `AVAudioPCMBuffer` is not `Sendable`. A chunk is created once on the capture
/// thread and never mutated afterwards, which is why the wrapper is marked
/// `@unchecked Sendable`. Consumers must treat `buffer` as read-only.
public struct AudioChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    /// Seconds from the first frame written to the recording file.
    public let startTime: TimeInterval

    public init(buffer: AVAudioPCMBuffer, startTime: TimeInterval) {
        self.buffer = buffer
        self.startTime = startTime
    }

    public var duration: TimeInterval {
        Double(buffer.frameLength) / buffer.format.sampleRate
    }

    public var sampleRate: Double { buffer.format.sampleRate }
}
