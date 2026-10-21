import AVFoundation
import Foundation
import Synchronization

/// Writes tapped buffers to an `AVAudioFile` and tracks the file timeline.
///
/// Called from the audio engine's tap thread. All mutable state sits behind a
/// `Mutex` so `elapsed` can be read safely from other threads and so a late
/// buffer after `close()` is ignored instead of crashing.
final class CaptureFileWriter: Sendable {
    private struct State {
        var file: AVAudioFile?
        var framesWritten: AVAudioFramePosition = 0
        var converter: AVAudioConverter?
        var lastError: String?
    }

    private let state: Mutex<State>
    let fileURL: URL
    let fileFormat: AVAudioFormat

    init(fileURL: URL, format: AVAudioFormat) throws {
        self.fileURL = fileURL
        self.fileFormat = format
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        } catch {
            throw AudioCaptureError.fileCreationFailed(error.localizedDescription)
        }
        state = Mutex(State(file: file))
    }

    /// Seconds written so far.
    var elapsed: TimeInterval {
        state.withLock { Double($0.framesWritten) / fileFormat.sampleRate }
    }

    var lastError: String? {
        state.withLock { $0.lastError }
    }

    /// Appends `buffer`, converting if its format differs from the file format
    /// (which can happen after a route change). Returns the chunk positioned on
    /// the file timeline, or `nil` if the writer is closed or the write failed.
    func append(_ buffer: AVAudioPCMBuffer) -> AudioChunk? {
        state.withLock { state -> AudioChunk? in
            guard let file = state.file else { return nil }
            let startTime = Double(state.framesWritten) / fileFormat.sampleRate
            let toWrite: AVAudioPCMBuffer
            if buffer.format == fileFormat {
                toWrite = buffer
            } else {
                guard let converted = Self.convert(buffer, to: fileFormat, converter: &state.converter) else {
                    state.lastError = "Could not convert input audio to the recording format."
                    return nil
                }
                toWrite = converted
            }
            do {
                try file.write(from: toWrite)
            } catch {
                state.lastError = error.localizedDescription
                return nil
            }
            state.framesWritten += AVAudioFramePosition(toWrite.frameLength)
            // The tap's buffer belongs to the engine and is not guaranteed to
            // stay unchanged after the tap block returns, while consumers read
            // chunks asynchronously. Hand them an owned copy.
            let owned = toWrite === buffer ? (buffer.ownedCopy() ?? buffer) : toWrite
            return AudioChunk(buffer: owned, startTime: startTime)
        }
    }

    /// Closes the file. Further appends are ignored.
    func close() -> TimeInterval {
        state.withLock { state in
            state.file = nil // AVAudioFile flushes and closes on deinit.
            return Double(state.framesWritten) / fileFormat.sampleRate
        }
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat,
        converter: inout AVAudioConverter?
    ) -> AVAudioPCMBuffer? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
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
        guard status != .error, conversionError == nil else { return nil }
        return output
    }
}

extension AVAudioPCMBuffer {
    /// A newly allocated buffer with the same format and sample data.
    func ownedCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { return nil }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}
