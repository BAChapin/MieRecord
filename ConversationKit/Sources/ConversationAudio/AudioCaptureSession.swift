import AVFoundation
import Foundation

/// Captures microphone audio with `AVAudioEngine`, writes it durably to a file,
/// and fans buffers out to `chunks` for live consumers.
///
/// Concurrency notes:
/// - The engine tap runs on a real-time audio thread. It only touches the
///   `CaptureFileWriter` (lock-protected) and two `AsyncStream` continuations;
///   it never hops to the actor.
/// - `chunks` uses `.bufferingNewest`, so a stalled transcription consumer loses
///   transcript coverage but never blocks the file writer (SPEC FR-2).
/// - Timestamps are derived from frames written to the file, so an interruption
///   pauses the timeline instead of leaving a silent gap.
public actor AudioCaptureSession: AudioCaptureSource {
    public struct Configuration: Sendable {
        /// Frames per tap callback. 4800 ≈ 100 ms at 48 kHz.
        public var tapBufferSize: AVAudioFrameCount = 4800
        /// Maximum chunks held for a slow consumer before oldest are dropped.
        public var chunkBufferLimit: Int = 64
        public init() {}
    }

    public nonisolated let chunks: AsyncStream<AudioChunk>
    public nonisolated let events: AsyncStream<AudioCaptureEvent>

    private let chunkContinuation: AsyncStream<AudioChunk>.Continuation
    private let eventContinuation: AsyncStream<AudioCaptureEvent>.Continuation
    private let fileURL: URL
    private let configuration: Configuration

    private var engine: AVAudioEngine?
    private var writer: CaptureFileWriter?
    private var observers: [any NSObjectProtocol] = []
    private var isInterrupted = false
    private var hasStarted = false
    private var hasStopped = false

    public init(fileURL: URL, configuration: Configuration = Configuration()) {
        self.fileURL = fileURL
        self.configuration = configuration
        (chunks, chunkContinuation) = AsyncStream.makeStream(
            of: AudioChunk.self,
            bufferingPolicy: .bufferingNewest(configuration.chunkBufferLimit)
        )
        (events, eventContinuation) = AsyncStream.makeStream(of: AudioCaptureEvent.self)
    }

    // MARK: - AudioCaptureSource

    public func start() async throws -> AudioStreamDescription {
        guard !hasStarted else { throw AudioCaptureError.alreadyStarted }
        hasStarted = true

        #if os(iOS)
        try AudioSessionController.activateForRecording()
        #endif

        let engine = AVAudioEngine()
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.inputUnavailable
        }

        let writer = try CaptureFileWriter(fileURL: fileURL, format: inputFormat)
        self.writer = writer
        self.engine = engine

        installTap(on: engine, format: inputFormat, writer: writer)
        registerObservers(for: engine)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw AudioCaptureError.engineStartFailed(error.localizedDescription)
        }

        let description = AudioStreamDescription(
            sampleRate: inputFormat.sampleRate,
            channelCount: Int(inputFormat.channelCount)
        )
        eventContinuation.yield(.started(sampleRate: description.sampleRate, channelCount: description.channelCount))
        return description
    }

    public func stop() async throws -> AudioCaptureSummary {
        guard hasStarted, let writer else { throw AudioCaptureError.notStarted }
        guard !hasStopped else {
            return summary(duration: writer.elapsed, writer: writer)
        }
        hasStopped = true

        removeObservers()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil

        let duration = writer.close()
        chunkContinuation.finish()
        eventContinuation.finish()

        #if os(iOS)
        AudioSessionController.deactivate()
        #endif
        return summary(duration: duration, writer: writer)
    }

    /// Seconds of audio written so far.
    public var elapsed: TimeInterval { writer?.elapsed ?? 0 }

    // MARK: - Tap

    private func installTap(on engine: AVAudioEngine, format: AVAudioFormat, writer: CaptureFileWriter) {
        let chunkContinuation = chunkContinuation
        let eventContinuation = eventContinuation
        engine.inputNode.installTap(onBus: 0, bufferSize: configuration.tapBufferSize, format: format) { buffer, _ in
            if let chunk = writer.append(buffer) {
                chunkContinuation.yield(chunk)
                eventContinuation.yield(.progress(elapsed: chunk.startTime + chunk.duration))
            } else if let message = writer.lastError {
                eventContinuation.yield(.failed(message: message))
            }
        }
    }

    // MARK: - Interruptions and configuration changes

    private func registerObservers(for engine: AVAudioEngine) {
        let center = NotificationCenter.default

        #if os(iOS)
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            guard
                let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: rawType)
            else { return }
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            Task { await self.handleInterruption(began: type == .began, shouldResume: shouldResume) }
        })
        #endif

        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleConfigurationChange() }
        })
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func handleInterruption(began: Bool, shouldResume: Bool) {
        guard !hasStopped, let engine else { return }
        if began {
            isInterrupted = true
            engine.pause()
            eventContinuation.yield(.interruptionBegan)
        } else {
            isInterrupted = false
            guard shouldResume else {
                eventContinuation.yield(.interruptionEnded(resumed: false))
                return
            }
            do {
                #if os(iOS)
                try AVAudioSession.sharedInstance().setActive(true)
                #endif
                try engine.start()
                eventContinuation.yield(.interruptionEnded(resumed: true))
            } catch {
                eventContinuation.yield(.interruptionEnded(resumed: false))
                eventContinuation.yield(.failed(message: "Could not resume after interruption: \(error.localizedDescription)"))
            }
        }
    }

    /// Re-arms the tap when the input format changes (e.g. headset connected).
    /// The writer converts mismatched buffers to the original file format.
    private func handleConfigurationChange() {
        guard !hasStopped, !isInterrupted, let engine, let writer else { return }
        engine.inputNode.removeTap(onBus: 0)
        let newFormat = engine.inputNode.outputFormat(forBus: 0)
        guard newFormat.sampleRate > 0, newFormat.channelCount > 0 else {
            eventContinuation.yield(.failed(message: "Audio input became unavailable."))
            return
        }
        installTap(on: engine, format: newFormat, writer: writer)
        do {
            if !engine.isRunning {
                try engine.start()
            }
            eventContinuation.yield(.configurationChanged)
        } catch {
            eventContinuation.yield(.failed(message: "Could not restart audio after a configuration change: \(error.localizedDescription)"))
        }
    }

    private func summary(duration: TimeInterval, writer: CaptureFileWriter) -> AudioCaptureSummary {
        AudioCaptureSummary(
            fileURL: fileURL,
            duration: duration,
            sampleRate: writer.fileFormat.sampleRate,
            channelCount: Int(writer.fileFormat.channelCount)
        )
    }
}
