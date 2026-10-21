import AVFoundation
import Foundation

/// Converts PCM buffers between formats (sample rate, channel layout, sample
/// type) for engines whose preferred input differs from the capture format.
///
/// Not thread-safe; use from a single task.
final class PCMBufferConverter {
    private var converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format == outputFormat { return buffer }

        if converter == nil || converter?.inputFormat != buffer.format {
            guard let created = AVAudioConverter(from: buffer.format, to: outputFormat) else {
                throw TranscriptionError.audioConversionFailed
            }
            created.primeMethod = .none
            converter = created
        }
        guard let converter else { throw TranscriptionError.audioConversionFailed }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        // Resampling converters release held-back samples in bursts (up to ~2x
        // a normal output), so leave generous headroom.
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio * 2).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw TranscriptionError.audioConversionFailed
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error || conversionError != nil {
            throw TranscriptionError.audioConversionFailed
        }
        return output
    }

    /// Drains samples the converter is still holding at end of input.
    /// The converter cannot be used afterwards.
    func flush() throws -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else {
            throw TranscriptionError.audioConversionFailed
        }
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        if status == .error || conversionError != nil {
            throw TranscriptionError.audioConversionFailed
        }
        return output.frameLength > 0 ? output : nil
    }
}
