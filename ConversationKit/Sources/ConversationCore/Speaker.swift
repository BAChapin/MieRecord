import Foundation

// MARK: - Recording-local speaker structure (populated by Milestone 2 diarization)

/// A distinct voice detected within one recording. Cluster identity is
/// recording-local and implies nothing across recordings (SPEC FR-4).
public struct SpeakerCluster: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var recordingID: UUID
    /// Start time of the cluster's first turn, used for `Speaker N` numbering.
    public var firstAppearance: TimeInterval

    public init(id: UUID = UUID(), recordingID: UUID, firstAppearance: TimeInterval) {
        self.id = id
        self.recordingID = recordingID
        self.firstAppearance = firstAppearance
    }
}

/// One contiguous stretch of speech attributed to a cluster.
public struct SpeakerTurn: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var recordingID: UUID
    public var clusterID: UUID
    public var timeRange: TimeRange
    /// True when diarization flagged overlapping speech or low certainty.
    public var isUncertain: Bool

    public init(id: UUID = UUID(), recordingID: UUID, clusterID: UUID, timeRange: TimeRange, isUncertain: Bool = false) {
        self.id = id
        self.recordingID = recordingID
        self.clusterID = clusterID
        self.timeRange = timeRange
        self.isUncertain = isUncertain
    }
}

/// Recording-local speaker structure produced by diarization.
public struct SpeakerTimeline: Hashable, Sendable {
    public var clusters: [SpeakerCluster]
    public var turns: [SpeakerTurn]

    public init(clusters: [SpeakerCluster], turns: [SpeakerTurn]) {
        self.clusters = clusters
        self.turns = turns
    }

    public static let empty = SpeakerTimeline(clusters: [], turns: [])

    /// Sorts turns, drops clusters that own no turns, drops turns that point at
    /// unknown clusters or have no duration, and recomputes each cluster's first
    /// appearance from its turns. Keeps engine output from breaking numbering.
    public func normalized() -> SpeakerTimeline {
        let known = Set(clusters.map(\.id))
        let validTurns = turns
            .filter { known.contains($0.clusterID) && $0.timeRange.duration > 0 }
            .sorted { $0.timeRange.start < $1.timeRange.start }
        var firstStart: [UUID: TimeInterval] = [:]
        for turn in validTurns where firstStart[turn.clusterID] == nil {
            firstStart[turn.clusterID] = turn.timeRange.start
        }
        let validClusters = clusters.compactMap { cluster -> SpeakerCluster? in
            guard let start = firstStart[cluster.id] else { return nil }
            var updated = cluster
            updated.firstAppearance = start
            return updated
        }
        .sorted { $0.firstAppearance < $1.firstAppearance }
        return SpeakerTimeline(clusters: validClusters, turns: validTurns)
    }
}

/// Display labels for a recording's speakers.
///
/// Labels are presentation only and are recomputed from stable cluster IDs
/// every time; application logic never keys off label strings (SPEC FR-7).
public enum SpeakerLabels {
    /// - Parameter identified: display names for clusters resolved to a known
    ///   profile (empty until identity matching exists). Those clusters do not
    ///   consume a `Speaker N` number.
    public static func labels(
        for clusters: [SpeakerCluster],
        identified: [UUID: String] = [:]
    ) -> [UUID: String] {
        let numbers = UnknownSpeakerNumbering.numbers(for: clusters, identifiedClusterIDs: Set(identified.keys))
        var labels = identified
        for (id, number) in numbers {
            labels[id] = UnknownSpeakerNumbering.label(forLocalSpeakerNumber: number)
        }
        return labels
    }

    /// Labels for the speakers that actually own transcript text, numbered by
    /// their first segment. Clusters left without text after corrections do
    /// not consume a number, so labels stay gap-free (`Speaker 1, 2, …`).
    public static func labels(
        forSegments segments: [TranscriptSegment],
        identified: [UUID: String] = [:]
    ) -> [UUID: String] {
        var firstAppearance: [UUID: TimeInterval] = [:]
        for segment in segments {
            guard let clusterID = segment.speakerClusterID else { continue }
            let start = segment.timeRange?.start ?? .greatestFiniteMagnitude
            firstAppearance[clusterID] = min(firstAppearance[clusterID] ?? .greatestFiniteMagnitude, start)
        }
        let numbers = UnknownSpeakerNumbering.numbers(
            firstAppearances: firstAppearance,
            identifiedClusterIDs: Set(identified.keys)
        )
        var labels = identified.filter { firstAppearance[$0.key] != nil }
        for (id, number) in numbers {
            labels[id] = UnknownSpeakerNumbering.label(forLocalSpeakerNumber: number)
        }
        return labels
    }
}
