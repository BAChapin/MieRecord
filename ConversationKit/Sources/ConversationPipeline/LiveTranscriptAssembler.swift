import ConversationCore
import ConversationML
import Foundation

/// The transcript as shown during recording: finalized segments plus at most one
/// provisional hypothesis.
public struct LiveTranscript: Sendable, Equatable {
    public var finalizedSegments: [TranscriptSegment] = []
    public var volatileText: String = ""
    public var volatileRange: TimeRange?

    public init(finalizedSegments: [TranscriptSegment] = [], volatileText: String = "", volatileRange: TimeRange? = nil) {
        self.finalizedSegments = finalizedSegments
        self.volatileText = volatileText
        self.volatileRange = volatileRange
    }

    /// Finalized text joined for display or plain-text export.
    public var finalizedText: String {
        finalizedSegments.map(\.text).joined(separator: " ")
    }
}

/// Folds `TranscriptionEvent`s into a `LiveTranscript`.
///
/// Apple's transcriber reports a volatile hypothesis repeatedly for the same
/// audio range and then a single finalized result that supersedes it. The
/// assembler therefore keeps only the latest volatile text and converts each
/// finalized result into exactly one persisted segment, so words are never
/// duplicated when a hypothesis is replaced (SPEC FR-2).
public struct LiveTranscriptAssembler: Sendable {
    public let recordingID: UUID
    public let source: EngineDescriptor
    public private(set) var transcript = LiveTranscript()

    public init(recordingID: UUID, source: EngineDescriptor) {
        self.recordingID = recordingID
        self.source = source
    }

    /// Applies one event and returns the newly finalized segment, if any.
    @discardableResult
    public mutating func apply(_ event: TranscriptionEvent) -> TranscriptSegment? {
        switch event {
        case let .volatile(text, range):
            transcript.volatileText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            transcript.volatileRange = range
            return nil

        case let .finalized(text, range, confidence):
            transcript.volatileText = ""
            transcript.volatileRange = nil
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let segment = TranscriptSegment(
                recordingID: recordingID,
                timeRange: range,
                text: trimmed,
                isFinal: true,
                source: source,
                transcriptionConfidence: confidence
            )
            transcript.finalizedSegments.append(segment)
            return segment
        }
    }

    /// Called when the engine finishes or fails: any remaining provisional text
    /// is promoted to a final segment so it is not lost, marked as provisional
    /// in origin via `isFinal == false`.
    @discardableResult
    public mutating func flushVolatile() -> TranscriptSegment? {
        let text = transcript.volatileText
        let range = transcript.volatileRange
        transcript.volatileText = ""
        transcript.volatileRange = nil
        guard !text.isEmpty else { return nil }
        let segment = TranscriptSegment(
            recordingID: recordingID,
            timeRange: range,
            text: text,
            isFinal: false,
            source: source
        )
        transcript.finalizedSegments.append(segment)
        return segment
    }
}
