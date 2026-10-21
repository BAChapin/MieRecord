import Foundation

/// One recognized word with its position on the recording timeline.
///
/// `text` keeps the engine's spacing and attached punctuation (for example
/// `" test."`), so concatenating a run of words reproduces the original text.
public struct TimedWord: Hashable, Codable, Sendable {
    public var text: String
    public var timeRange: TimeRange
    public var confidence: Double?

    public init(text: String, timeRange: TimeRange, confidence: Double? = nil) {
        self.text = text
        self.timeRange = timeRange
        self.confidence = confidence
    }
}

/// A span of transcribed text on a recording's timeline.
///
/// Segments are produced by the live transcription engine during recording and
/// later re-attributed to speaker clusters by post-processing. `speakerClusterID`
/// stays `nil` until diarization runs (or for unresolved overlaps).
public struct TranscriptSegment: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var recordingID: UUID
    /// `nil` when the engine did not supply timing for this result.
    public var timeRange: TimeRange?
    public var text: String
    /// `false` for provisional hypotheses that may still be replaced.
    public var isFinal: Bool
    public var source: EngineDescriptor
    /// Recording-local speaker cluster, assigned by post-processing.
    public var speakerClusterID: UUID?
    /// Transcription confidence from the engine, in [0, 1], when provided.
    /// This is *not* speaker identity confidence.
    public var transcriptionConfidence: Double?
    /// Set when the user edited the text; user edits are authoritative across
    /// reprocessing (SPEC FR-6).
    public var editedAt: Date?
    /// Word-level timing when the engine provided it. Used to split segments
    /// at speaker changes. Empty for older or edited transcripts.
    public var words: [TimedWord]
    /// True when the user chose this segment's speaker. Reprocessing must not
    /// silently replace it (SPEC FR-6).
    public var speakerAssignedByUser: Bool
    /// True when attribution is ambiguous (overlapping speech, a turn boundary
    /// inside the segment, or no nearby turn). Shown for review rather than
    /// forced (SPEC FR-3).
    public var speakerIsUncertain: Bool

    public init(
        id: UUID = UUID(),
        recordingID: UUID,
        timeRange: TimeRange?,
        text: String,
        isFinal: Bool,
        source: EngineDescriptor,
        speakerClusterID: UUID? = nil,
        transcriptionConfidence: Double? = nil,
        editedAt: Date? = nil,
        words: [TimedWord] = [],
        speakerAssignedByUser: Bool = false,
        speakerIsUncertain: Bool = false
    ) {
        self.id = id
        self.recordingID = recordingID
        self.timeRange = timeRange
        self.text = text
        self.isFinal = isFinal
        self.source = source
        self.speakerClusterID = speakerClusterID
        self.transcriptionConfidence = transcriptionConfidence
        self.editedAt = editedAt
        self.words = words
        self.speakerAssignedByUser = speakerAssignedByUser
        self.speakerIsUncertain = speakerIsUncertain
    }

    /// Whether the user changed anything that reprocessing would overwrite.
    public var hasUserEdits: Bool {
        editedAt != nil || speakerAssignedByUser
    }
}

extension Array where Element == TranscriptSegment {
    /// Segments ordered by start time; untimed segments keep relative order and
    /// sort last.
    public func sortedByTime() -> [TranscriptSegment] {
        enumerated().sorted { lhs, rhs in
            switch (lhs.element.timeRange?.start, rhs.element.timeRange?.start) {
            case let (l?, r?): l != r ? l < r : lhs.offset < rhs.offset
            case (nil, nil): lhs.offset < rhs.offset
            case (nil, _?): false
            case (_?, nil): true
            }
        }.map(\.element)
    }
}
