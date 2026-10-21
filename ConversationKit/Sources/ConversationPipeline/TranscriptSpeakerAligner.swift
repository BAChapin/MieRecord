import ConversationCore
import Foundation

/// Assigns transcript text to diarized speakers (SPEC FR-3 step 6).
///
/// With word timings, each word goes to the cluster whose turns overlap it
/// most, and a segment is split wherever the speaker changes, so a sentence
/// that crosses a turn boundary becomes two attributed segments. Without word
/// timings (older or user-edited text), the whole segment goes to its
/// dominant cluster and is marked uncertain when another speaker holds a
/// substantial share.
///
/// Ambiguity is preserved rather than forced: overlapping speech, words far
/// from any turn, and mixed segments are flagged `speakerIsUncertain`, and text
/// with no nearby turn keeps a nil cluster. Segments whose speaker the user
/// chose are returned unchanged.
public enum TranscriptSpeakerAligner {
    public struct Configuration: Sendable {
        /// Text this far from the nearest turn is left unattributed.
        public var maxNearestDistance: TimeInterval = 1.0
        /// Snapping to a turn farther than this marks the text uncertain.
        public var confidentNearestDistance: TimeInterval = 0.5
        /// A runner-up speaker covering at least this share of the winner's
        /// overlap marks a word as overlapping speech.
        public var overlapRatio: Double = 0.5
        /// A runner-up covering at least this share of a whole segment marks a
        /// segment-level assignment as mixed.
        public var mixedSegmentShare: Double = 0.3
        /// A runner-up holding at least this many seconds of a segment also
        /// marks it mixed: long enough for someone else to have said words.
        public var mixedSegmentSeconds: TimeInterval = 0.5

        public init() {}
    }

    public static func align(
        _ segments: [TranscriptSegment],
        to timeline: SpeakerTimeline,
        configuration: Configuration = Configuration()
    ) -> [TranscriptSegment] {
        let index = TurnIndex(turns: timeline.turns)
        var output: [TranscriptSegment] = []
        for segment in segments.sortedByTime() {
            if segment.speakerAssignedByUser {
                output.append(segment)
            } else if timeline.turns.isEmpty {
                var cleared = segment
                cleared.speakerClusterID = nil
                cleared.speakerIsUncertain = false
                output.append(cleared)
            } else if segment.words.isEmpty || segment.editedAt != nil {
                output.append(alignWhole(segment, index: index, configuration: configuration))
            } else {
                output.append(contentsOf: alignByWord(segment, index: index, configuration: configuration))
            }
        }
        return output
    }

    // MARK: - Segment level

    private static func alignWhole(_ segment: TranscriptSegment, index: TurnIndex, configuration: Configuration) -> TranscriptSegment {
        var result = segment
        guard let range = segment.timeRange else {
            result.speakerClusterID = nil
            result.speakerIsUncertain = true
            return result
        }
        let ranked = index.rankedOverlap(with: range)
        if let best = ranked.first {
            result.speakerClusterID = best.clusterID
            let runnerUp = ranked.dropFirst().first?.seconds ?? 0
            result.speakerIsUncertain = runnerUp >= configuration.mixedSegmentSeconds
                || (range.duration > 0 && runnerUp / range.duration >= configuration.mixedSegmentShare)
        } else if let nearest = index.nearest(to: range), nearest.distance <= configuration.maxNearestDistance {
            result.speakerClusterID = nearest.clusterID
            result.speakerIsUncertain = nearest.distance > configuration.confidentNearestDistance
        } else {
            result.speakerClusterID = nil
            result.speakerIsUncertain = true
        }
        return result
    }

    // MARK: - Word level

    private struct WordAssignment {
        var word: TimedWord
        var clusterID: UUID?
        var uncertain: Bool
    }

    private static func alignByWord(_ segment: TranscriptSegment, index: TurnIndex, configuration: Configuration) -> [TranscriptSegment] {
        var assignments = segment.words.map { word -> WordAssignment in
            let ranked = index.rankedOverlap(with: word.timeRange)
            if let best = ranked.first {
                let runnerUp = ranked.dropFirst().first?.seconds ?? 0
                return WordAssignment(word: word, clusterID: best.clusterID, uncertain: runnerUp >= best.seconds * configuration.overlapRatio)
            }
            if let nearest = index.nearest(to: word.timeRange), nearest.distance <= configuration.maxNearestDistance {
                return WordAssignment(word: word, clusterID: nearest.clusterID, uncertain: nearest.distance > configuration.confidentNearestDistance)
            }
            return WordAssignment(word: word, clusterID: nil, uncertain: true)
        }

        // A word with no nearby turn inherits its neighbor's speaker (previous,
        // else next) but stays flagged, instead of splitting off on its own.
        for i in assignments.indices where assignments[i].clusterID == nil {
            let neighbor = assignments[..<i].last { $0.clusterID != nil } ?? assignments[(i + 1)...].first { $0.clusterID != nil }
            assignments[i].clusterID = neighbor?.clusterID
        }

        // Group consecutive words with the same speaker into segments.
        var runs: [[WordAssignment]] = []
        for assignment in assignments {
            if let last = runs.last?.last, last.clusterID == assignment.clusterID {
                runs[runs.count - 1].append(assignment)
            } else {
                runs.append([assignment])
            }
        }

        return runs.enumerated().map { offset, run in
            let words = run.map(\.word)
            let confidences = words.compactMap(\.confidence)
            return TranscriptSegment(
                // The first piece keeps the original ID so references stay stable.
                id: offset == 0 ? segment.id : UUID(),
                recordingID: segment.recordingID,
                timeRange: TimeRange(start: words[0].timeRange.start, end: words[words.count - 1].timeRange.end),
                text: words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
                isFinal: segment.isFinal,
                source: segment.source,
                speakerClusterID: run[0].clusterID,
                transcriptionConfidence: confidences.isEmpty
                    ? segment.transcriptionConfidence
                    : confidences.reduce(0, +) / Double(confidences.count),
                editedAt: nil,
                words: words,
                speakerAssignedByUser: false,
                speakerIsUncertain: run.contains(where: \.uncertain)
            )
        }
    }

    // MARK: - Turn lookup

    private struct TurnIndex {
        let turns: [SpeakerTurn]

        /// Clusters overlapping `range`, by total overlapped seconds, largest first.
        func rankedOverlap(with range: TimeRange) -> [(clusterID: UUID, seconds: TimeInterval)] {
            var totals: [UUID: TimeInterval] = [:]
            for turn in turns {
                let overlap = min(turn.timeRange.end, range.end) - max(turn.timeRange.start, range.start)
                if overlap > 0 {
                    totals[turn.clusterID, default: 0] += overlap
                }
            }
            return totals
                .map { (clusterID: $0.key, seconds: $0.value) }
                .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.clusterID.uuidString < $1.clusterID.uuidString }
        }

        func nearest(to range: TimeRange) -> (clusterID: UUID, distance: TimeInterval)? {
            turns
                .map { turn in
                    (clusterID: turn.clusterID,
                     distance: max(0, max(turn.timeRange.start - range.end, range.start - turn.timeRange.end)))
                }
                .min { $0.distance < $1.distance }
        }
    }
}
