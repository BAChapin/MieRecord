import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import ConversationML

@Suite("Analyzer input timestamps (regression: SFSpeechErrorDomain 17)")
struct AnalyzerTimelineTests {
    @Test("stamps are contiguous and never move backwards")
    func contiguous() {
        var timeline = AnalyzerTimeline(sampleRate: 16_000)
        timeline.noteInputChunk(startingAt: 0)
        #expect(timeline.stamp(frameCount: 1365).value == 0)
        timeline.noteInputChunk(startingAt: 0.1)
        #expect(timeline.stamp(frameCount: 2774).value == 1365)
        // The next input chunk "starts" before the clock (burst put us ahead):
        // the clock must not move back.
        timeline.noteInputChunk(startingAt: 0.2)
        #expect(timeline.stamp(frameCount: 1365).value == 4139)
    }

    @Test("a real upstream gap moves the clock forward to the file timeline")
    func gap() {
        var timeline = AnalyzerTimeline(sampleRate: 16_000)
        timeline.noteInputChunk(startingAt: 0)
        _ = timeline.stamp(frameCount: 1600)
        timeline.noteInputChunk(startingAt: 2.0) // 1.9 s of chunks were dropped
        #expect(timeline.stamp(frameCount: 1600).value == 32_000)
    }

    @Test("converter latency below the tolerance is not treated as a gap")
    func latencyIsNotGap() {
        var timeline = AnalyzerTimeline(sampleRate: 16_000)
        timeline.noteInputChunk(startingAt: 0)
        _ = timeline.stamp(frameCount: 1365) // converter held back 235 samples
        timeline.noteInputChunk(startingAt: 0.1)
        #expect(timeline.stamp(frameCount: 1365).value == 1365)
    }

    /// Runs the real resampler with the device's capture format and the
    /// analyzer's format, the combination that failed on iPhone, and checks
    /// that no submitted buffer overlaps its predecessor.
    @Test("48 kHz Float32 → 16 kHz Int16 conversion yields non-overlapping input", arguments: [4096, 4800, 5553])
    func realConverterNoOverlap(chunkFrames: Int) throws {
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let output = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let converter = PCMBufferConverter(outputFormat: output)
        var timeline = AnalyzerTimeline(sampleRate: output.sampleRate)

        var inputFrames = 0
        var previousEnd: Int64 = 0
        var outputFrames: Int64 = 0
        for _ in 0..<60 {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(chunkFrames)))
            buffer.frameLength = AVAudioFrameCount(chunkFrames)
            let samples = try #require(buffer.floatChannelData?[0])
            for i in 0..<chunkFrames {
                samples[i] = sinf(Float(inputFrames + i) * 2 * .pi * 440 / 48_000) * 0.5
            }
            timeline.noteInputChunk(startingAt: Double(inputFrames) / input.sampleRate)
            inputFrames += chunkFrames

            let converted = try converter.convert(buffer)
            guard converted.frameLength > 0 else { continue }
            let start = timeline.stamp(frameCount: converted.frameLength).value
            #expect(start >= previousEnd, "buffer at \(start) overlaps previous end \(previousEnd)")
            previousEnd = start + Int64(converted.frameLength)
            outputFrames += Int64(converted.frameLength)
        }
        if let tail = try converter.flush() {
            outputFrames += Int64(tail.frameLength)
        }
        // Everything that went in came out (within resampler rounding).
        let expected = Double(inputFrames) / 3
        #expect(abs(Double(outputFrames) - expected) < 32)
    }
}
