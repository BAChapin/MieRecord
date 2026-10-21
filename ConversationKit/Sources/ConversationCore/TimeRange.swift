import Foundation

/// A closed interval on a recording's own timeline, measured in seconds from the
/// first audio frame written to the recording file.
///
/// All timing in ConversationKit uses the *file* timeline rather than wall-clock
/// time, so pauses and audio-session interruptions never shift later timestamps.
public struct TimeRange: Hashable, Codable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval

    /// Creates a range, clamping `end` so it is never earlier than `start`.
    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = max(start, end)
    }

    public var duration: TimeInterval { end - start }

    public func overlaps(_ other: TimeRange) -> Bool {
        start < other.end && other.start < end
    }

    public func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}
