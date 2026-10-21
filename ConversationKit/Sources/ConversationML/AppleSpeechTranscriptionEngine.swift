import AVFoundation
import ConversationAudio
import ConversationCore
import CoreMedia
import Foundation
import Speech

/// Live transcription using Apple's on-device `SpeechAnalyzer` /
/// `SpeechTranscriber` (iOS 26+). Runs entirely on device once the locale's
/// speech assets are installed; asset download is the only network activity and
/// only happens through `prepare()`.
///
/// Timing: each chunk is tagged with its file-timeline start, so result ranges
/// are already aligned to the recording file and survive interruptions.
public final class AppleSpeechTranscriptionEngine: StreamingTranscriptionEngine, FileTranscriptionEngine {
    public let locale: Locale
    public let descriptor = EngineDescriptor(identifier: "apple.speech.transcriber", version: "ios26")
    /// Distinguishes segments produced by a whole-file pass from live ones.
    public let fileDescriptor = EngineDescriptor(identifier: "apple.speech.transcriber.file", version: "ios26")

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    // MARK: - Availability

    public func availability() async -> TranscriptionAvailability {
        guard SpeechTranscriber.isAvailable else {
            return .unsupported(reason: "On-device speech transcription is not available on this device.")
        }
        guard await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            return .unsupported(reason: "Speech transcription does not support the \(locale.identifier) locale.")
        }
        let transcriber = makeTranscriber()
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return .available
        case .supported, .downloading:
            return .assetsRequired
        case .unsupported:
            return .unsupported(reason: "No speech assets are available for \(locale.identifier).")
        @unknown default:
            return .unsupported(reason: "Unknown speech asset status.")
        }
    }

    public func prepare() async throws {
        let transcriber = makeTranscriber()
        try await ensureAssets(for: transcriber)
    }

    // MARK: - Transcription

    public func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self)
        let descriptor = descriptor
        let transcriber = makeTranscriber()

        let task = Task { [self] in
            do {
                try await ensureAssets(for: transcriber)

                guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                    throw TranscriptionError.noCompatibleAudioFormat
                }

                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let (inputSequence, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

                // Results are consumed concurrently with input so volatile
                // hypotheses reach the UI while audio is still arriving.
                let resultsTask = Task {
                    for try await result in transcriber.results {
                        continuation.yield(Self.event(from: result))
                    }
                }

                try await analyzer.start(inputSequence: inputSequence)

                // Timestamps come from the analyzer-side sample clock, never
                // from the input chunk; see `AnalyzerTimeline` for why.
                let converter = PCMBufferConverter(outputFormat: analyzerFormat)
                var timeline = AnalyzerTimeline(sampleRate: analyzerFormat.sampleRate)
                for await chunk in audio {
                    try Task.checkCancellation()
                    timeline.noteInputChunk(startingAt: chunk.startTime)
                    let converted = try converter.convert(chunk.buffer)
                    guard converted.frameLength > 0 else { continue }
                    let start = timeline.stamp(frameCount: converted.frameLength)
                    inputContinuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: start))
                }
                if let tail = try converter.flush() {
                    let start = timeline.stamp(frameCount: tail.frameLength)
                    inputContinuation.yield(AnalyzerInput(buffer: tail, bufferStartTime: start))
                }
                inputContinuation.finish()

                try await analyzer.finalizeAndFinishThroughEndOfInput()
                try await resultsTask.value
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch let error as TranscriptionError {
                continuation.finish(throwing: error)
            } catch {
                continuation.finish(throwing: TranscriptionError.engineFailure("\(descriptor.identifier): \(error.localizedDescription)"))
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: - Whole-file transcription

    public func transcribeFile(
        at url: URL,
        progress: @escaping @Sendable (TimeInterval) -> Void
    ) async throws -> [TranscribedSpan] {
        // Finalized results only: a file pass has no use for volatile text.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        try await ensureAssets(for: transcriber)

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw TranscriptionError.audioFileUnreadable(error.localizedDescription)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var spans: [TranscribedSpan] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                let range = Self.timeRange(from: result.range)
                if let end = range?.end { progress(end) }
                guard !text.isEmpty else { continue }
                spans.append(TranscribedSpan(text: text, timeRange: range, confidence: Self.meanConfidence(of: result.text)))
            }
            return spans
        }

        // SpeechAnalyzer reads and resamples the file itself and timestamps
        // results on the file's own timeline, which is the recording timeline.
        do {
            try await withTaskCancellationHandler {
                if let lastSample = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
            try Task.checkCancellation()
            return try await collector.value
        } catch is CancellationError {
            collector.cancel()
            throw CancellationError()
        } catch let error as TranscriptionError {
            collector.cancel()
            throw error
        } catch {
            collector.cancel()
            if Task.isCancelled { throw CancellationError() }
            throw TranscriptionError.engineFailure("\(fileDescriptor.identifier): \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }

    private func ensureAssets(for transcriber: SpeechTranscriber) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.assetsUnavailable("Speech transcription is unavailable on this device.")
        }
        guard await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            throw TranscriptionError.unsupportedLocale(locale.identifier)
        }
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                return // Nothing to install.
            }
            try await request.downloadAndInstall()
        case .unsupported:
            throw TranscriptionError.assetsUnavailable("No speech assets for \(locale.identifier).")
        @unknown default:
            throw TranscriptionError.assetsUnavailable("Unknown speech asset status.")
        }
    }

    private static func event(from result: SpeechTranscriber.Result) -> TranscriptionEvent {
        let text = String(result.text.characters)
        let range = Self.timeRange(from: result.range)
        if result.isFinal {
            return .finalized(text: text, timeRange: range, confidence: Self.meanConfidence(of: result.text))
        }
        return .volatile(text: text, timeRange: range)
    }

    private static func timeRange(from range: CMTimeRange) -> TimeRange? {
        guard range.start.isNumeric, range.duration.isNumeric else { return nil }
        let start = range.start.seconds
        return TimeRange(start: start, end: start + range.duration.seconds)
    }

    /// Mean per-run transcription confidence, weighted by character count.
    private static func meanConfidence(of text: AttributedString) -> Double? {
        var weighted = 0.0
        var total = 0
        for run in text.runs {
            guard let confidence = run.transcriptionConfidence else { continue }
            let length = text.characters[run.range].count
            weighted += confidence * Double(length)
            total += length
        }
        return total > 0 ? weighted / Double(total) : nil
    }
}
