import Foundation

/// Small vector helpers for speaker embeddings.
public enum VectorMath {
    public static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 1e-9 else { return vector }
        return vector.map { $0 / norm }
    }

    /// Cosine similarity in [-1, 1]; 0 for mismatched or empty vectors.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denominator = (na * nb).squareRoot()
        return denominator > 1e-9 ? Double(dot / denominator) : 0
    }

    /// Normalized mean of normalized vectors (a direction, not a magnitude).
    public static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors where vector.count == first.count {
            let unit = normalized(vector)
            for i in sum.indices { sum[i] += unit[i] }
        }
        return normalized(sum)
    }

    /// Compact binary storage for vectors (native Float32 bytes).
    public static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// A speaker embedding for one analysis window of a recording, as produced by
/// the diarization engine and attributed to one recording-local cluster.
///
/// This is biometric-like data. It stays on device and is deleted with its
/// recording.
public struct WindowEmbedding: Hashable, Codable, Sendable {
    public var clusterID: UUID
    public var timeRange: TimeRange
    public var vector: [Float]

    public init(clusterID: UUID, timeRange: TimeRange, vector: [Float]) {
        self.clusterID = clusterID
        self.timeRange = timeRange
        self.vector = vector
    }
}

/// All window embeddings for a recording plus the engine that produced them.
public struct RecordingVoiceData: Hashable, Sendable {
    public var engine: EngineDescriptor
    public var windows: [WindowEmbedding]

    public init(engine: EngineDescriptor, windows: [WindowEmbedding]) {
        self.engine = engine
        self.windows = windows
    }
}

/// A cluster's summary voiceprint and the quality signals used to decide
/// whether it may be matched to a person at all.
public struct ClusterVoiceprint: Hashable, Sendable {
    public var clusterID: UUID
    public var engine: EngineDescriptor
    /// Normalized centroid of the cluster's window embeddings.
    public var vector: [Float]
    public var windowCount: Int
    /// Mean cosine of the windows to their centroid. Low values indicate the
    /// cluster mixes voices, which makes any identity claim unsafe.
    public var consistency: Double
    /// Seconds of the cluster's turns that do not overlap another speaker.
    public var cleanSpeechSeconds: Double

    public init(clusterID: UUID, engine: EngineDescriptor, vector: [Float], windowCount: Int, consistency: Double, cleanSpeechSeconds: Double) {
        self.clusterID = clusterID
        self.engine = engine
        self.vector = vector
        self.windowCount = windowCount
        self.consistency = consistency
        self.cleanSpeechSeconds = cleanSpeechSeconds
    }

    /// Builds one voiceprint per cluster that has window embeddings.
    public static func make(from data: RecordingVoiceData, timeline: SpeakerTimeline) -> [ClusterVoiceprint] {
        let byCluster = Dictionary(grouping: data.windows, by: \.clusterID)
        return timeline.clusters.compactMap { cluster in
            guard let windows = byCluster[cluster.id], let centroid = VectorMath.centroid(windows.map(\.vector)) else {
                return nil
            }
            let consistency = windows.map { VectorMath.cosine($0.vector, centroid) }.reduce(0, +) / Double(windows.count)
            return ClusterVoiceprint(
                clusterID: cluster.id,
                engine: data.engine,
                vector: centroid,
                windowCount: windows.count,
                consistency: consistency,
                cleanSpeechSeconds: cleanSpeech(of: cluster.id, in: timeline)
            )
        }
    }

    /// Duration of the cluster's turns minus any time another cluster also speaks.
    static func cleanSpeech(of clusterID: UUID, in timeline: SpeakerTimeline) -> Double {
        let own = timeline.turns.filter { $0.clusterID == clusterID && !$0.isUncertain }
        let others = timeline.turns.filter { $0.clusterID != clusterID }
        return own.reduce(0) { total, turn in
            let overlapped = others.reduce(0.0) { sum, other in
                sum + max(0, min(turn.timeRange.end, other.timeRange.end) - max(turn.timeRange.start, other.timeRange.start))
            }
            return total + max(0, turn.timeRange.duration - overlapped)
        }
    }
}
