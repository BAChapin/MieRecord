import ConversationCore
import Foundation
import Testing

@Suite("Identity confidence policy (SPEC FR-5)")
struct IdentityConfidencePolicyTests {
    let policy = IdentityConfidencePolicy.specDefault
    let profile = UUID()

    @Test("tiers follow the 60% / 80% thresholds, inclusive at the boundaries")
    func tiers() {
        #expect(policy.tier(forCalibratedConfidence: 0.0) == .unidentified)
        #expect(policy.tier(forCalibratedConfidence: 0.599) == .unidentified)
        #expect(policy.tier(forCalibratedConfidence: 0.60) == .needsVerification)
        #expect(policy.tier(forCalibratedConfidence: 0.799) == .needsVerification)
        #expect(policy.tier(forCalibratedConfidence: 0.80) == .recognized)
        #expect(policy.tier(forCalibratedConfidence: 1.0) == .recognized)
    }
}

@Suite("Unknown speaker numbering (SPEC FR-4)")
struct UnknownSpeakerNumberingTests {
    @Test("numbers follow first appearance and skip identified clusters")
    func numbering() {
        let recording = UUID()
        let known = SpeakerCluster(recordingID: recording, firstAppearance: 0)
        let unknownLate = SpeakerCluster(recordingID: recording, firstAppearance: 30)
        let unknownEarly = SpeakerCluster(recordingID: recording, firstAppearance: 5)

        let numbers = UnknownSpeakerNumbering.numbers(
            for: [unknownLate, known, unknownEarly],
            identifiedClusterIDs: [known.id]
        )
        #expect(numbers[known.id] == nil)
        #expect(numbers[unknownEarly.id] == 1)
        #expect(numbers[unknownLate.id] == 2)
        #expect(UnknownSpeakerNumbering.label(forLocalSpeakerNumber: 2) == "Speaker 2")
    }
}

@Suite("Domain value types")
struct DomainTypeTests {
    @Test("TimeRange clamps inverted ranges and tests overlap")
    func timeRange() {
        let inverted = TimeRange(start: 5, end: 2)
        #expect(inverted.end == 5)
        #expect(inverted.duration == 0)
        #expect(TimeRange(start: 0, end: 2).overlaps(TimeRange(start: 1, end: 3)))
        #expect(!TimeRange(start: 0, end: 2).overlaps(TimeRange(start: 2, end: 3)))
    }

    @Test("ProcessingState round-trips through JSON including associated values")
    func processingStateCodable() throws {
        let failure = ProcessingFailure(stage: .diarization, message: "boom", occurredAt: Date(timeIntervalSince1970: 1))
        let states: [ProcessingState] = [.notStarted, .queued, .processing(.alignment), .needsReview, .ready, .failed(failure)]
        for state in states {
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(ProcessingState.self, from: data)
            #expect(decoded == state)
        }
    }

    @Test("sortedByTime orders timed segments and keeps untimed last in arrival order")
    func sorting() {
        let recording = UUID()
        let source = EngineDescriptor(identifier: "test")
        let a = TranscriptSegment(recordingID: recording, timeRange: TimeRange(start: 10, end: 12), text: "a", isFinal: true, source: source)
        let b = TranscriptSegment(recordingID: recording, timeRange: nil, text: "b", isFinal: true, source: source)
        let c = TranscriptSegment(recordingID: recording, timeRange: TimeRange(start: 1, end: 2), text: "c", isFinal: true, source: source)
        let d = TranscriptSegment(recordingID: recording, timeRange: nil, text: "d", isFinal: true, source: source)
        #expect([a, b, c, d].sortedByTime().map(\.text) == ["c", "a", "b", "d"])
    }
}

@Suite("Speaker labels and timeline normalization")
struct SpeakerLabelTests {
    let recording = UUID()
    let source = EngineDescriptor(identifier: "t")

    @Test("segment-based labels skip speakers without text and identified speakers")
    func segmentLabels() {
        let a = UUID(), b = UUID(), known = UUID()
        let segments = [
            TranscriptSegment(recordingID: recording, timeRange: TimeRange(start: 0, end: 1), text: "k", isFinal: true, source: source, speakerClusterID: known),
            TranscriptSegment(recordingID: recording, timeRange: TimeRange(start: 2, end: 3), text: "b", isFinal: true, source: source, speakerClusterID: b),
            TranscriptSegment(recordingID: recording, timeRange: TimeRange(start: 4, end: 5), text: "a", isFinal: true, source: source, speakerClusterID: a),
            TranscriptSegment(recordingID: recording, timeRange: TimeRange(start: 6, end: 7), text: "b again", isFinal: true, source: source, speakerClusterID: b),
            TranscriptSegment(recordingID: recording, timeRange: TimeRange(start: 8, end: 9), text: "none", isFinal: true, source: source),
        ]
        let labels = SpeakerLabels.labels(forSegments: segments, identified: [known: "Brett", UUID(): "Absent"])
        #expect(labels == [known: "Brett", b: "Speaker 1", a: "Speaker 2"])
    }

    @Test("normalization drops empty clusters and dangling turns and recomputes first appearance")
    func normalize() {
        let a = SpeakerCluster(recordingID: recording, firstAppearance: 99)
        let empty = SpeakerCluster(recordingID: recording, firstAppearance: 0)
        let timeline = SpeakerTimeline(clusters: [a, empty], turns: [
            SpeakerTurn(recordingID: recording, clusterID: a.id, timeRange: TimeRange(start: 5, end: 6)),
            SpeakerTurn(recordingID: recording, clusterID: a.id, timeRange: TimeRange(start: 2, end: 3)),
            SpeakerTurn(recordingID: recording, clusterID: UUID(), timeRange: TimeRange(start: 1, end: 2)),
            SpeakerTurn(recordingID: recording, clusterID: a.id, timeRange: TimeRange(start: 4, end: 4)),
        ]).normalized()
        #expect(timeline.clusters.map(\.id) == [a.id])
        #expect(timeline.clusters[0].firstAppearance == 2)
        #expect(timeline.turns.map(\.timeRange.start) == [2, 5])
    }
}
