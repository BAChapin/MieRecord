import ConversationCore
import ConversationPipeline
import Foundation
import Testing

@Suite("Transcript-to-speaker alignment")
struct TranscriptSpeakerAlignerTests {
    let recording = UUID()
    let a = UUID()
    let b = UUID()
    let source = EngineDescriptor(identifier: "test")

    private func timeline(_ turns: [(UUID, Double, Double)]) -> SpeakerTimeline {
        SpeakerTimeline(
            clusters: [SpeakerCluster(id: a, recordingID: recording, firstAppearance: 0),
                       SpeakerCluster(id: b, recordingID: recording, firstAppearance: 0)],
            turns: turns.map { SpeakerTurn(recordingID: recording, clusterID: $0.0, timeRange: TimeRange(start: $0.1, end: $0.2)) }
        )
    }

    private func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
        TimedWord(text: text, timeRange: TimeRange(start: start, end: end), confidence: 0.9)
    }

    private func segment(_ words: [TimedWord], text: String? = nil, range: TimeRange? = nil) -> TranscriptSegment {
        TranscriptSegment(
            recordingID: recording,
            timeRange: range ?? words.first.map { TimeRange(start: $0.timeRange.start, end: words.last!.timeRange.end) },
            text: text ?? words.map(\.text).joined().trimmingCharacters(in: .whitespaces),
            isFinal: true,
            source: source,
            words: words
        )
    }

    @Test("a sentence crossing a turn boundary is split at the word where the speaker changes")
    func splitsAtSpeakerChange() {
        let original = segment([word("Are", 0, 0.3), word(" you", 0.3, 0.5), word(" there?", 0.5, 0.9),
                                word(" Yes,", 1.0, 1.3), word(" I", 1.3, 1.4), word(" am.", 1.4, 1.8)])
        let result = TranscriptSpeakerAligner.align([original], to: timeline([(a, 0, 0.95), (b, 0.95, 2)]))

        #expect(result.map(\.text) == ["Are you there?", "Yes, I am."])
        #expect(result.map(\.speakerClusterID) == [a, b])
        #expect(result[0].id == original.id, "first piece keeps the original ID")
        #expect(result[1].id != original.id)
        #expect(result[1].timeRange == TimeRange(start: 1.0, end: 1.8))
        #expect(result.allSatisfy { !$0.speakerIsUncertain })
    }

    @Test("a word inside overlapping turns is flagged uncertain")
    func overlapFlagged() {
        let original = segment([word("Hello", 0, 0.5), word(" there", 0.5, 1.0)])
        let result = TranscriptSpeakerAligner.align([original], to: timeline([(a, 0, 1.0), (b, 0.6, 1.0)]))
        #expect(result.count == 1)
        #expect(result[0].speakerClusterID == a)
        #expect(result[0].speakerIsUncertain)
    }

    @Test("a word in a short pause snaps to the nearest turn without being flagged")
    func shortGapSnaps() {
        let original = segment([word("Okay", 0, 0.4), word(" then", 0.55, 0.7)])
        let result = TranscriptSpeakerAligner.align([original], to: timeline([(a, 0, 0.45)]))
        #expect(result.count == 1)
        #expect(result[0].speakerClusterID == a)
        #expect(!result[0].speakerIsUncertain)
    }

    @Test("text far from any turn is left unattributed and flagged")
    func farFromTurns() {
        let original = segment([word("Echo", 10, 10.5)])
        let result = TranscriptSpeakerAligner.align([original], to: timeline([(a, 0, 1)]))
        #expect(result[0].speakerClusterID == nil)
        #expect(result[0].speakerIsUncertain)
    }

    @Test("without word timing the whole segment goes to the dominant speaker; a large runner-up share flags it")
    func segmentLevel() {
        let mostlyA = TranscriptSegment(recordingID: recording, timeRange: TimeRange(start: 0, end: 10), text: "long", isFinal: true, source: source)
        // Boundary jitter (0.2 s) is not treated as a second speaker.
        let clean = TranscriptSpeakerAligner.align([mostlyA], to: timeline([(a, 0, 9.8), (b, 9.8, 10)]))
        #expect(clean[0].speakerClusterID == a)
        #expect(!clean[0].speakerIsUncertain)

        let mixed = TranscriptSpeakerAligner.align([mostlyA], to: timeline([(a, 0, 6), (b, 6, 10)]))
        #expect(mixed[0].speakerClusterID == a)
        #expect(mixed[0].speakerIsUncertain)

        // A short interjection: small share, but long enough to be words.
        let interjection = TranscriptSpeakerAligner.align([mostlyA], to: timeline([(a, 0, 9), (b, 9, 10)]))
        #expect(interjection[0].speakerIsUncertain)
    }

    @Test("user-chosen speakers and edited text are respected")
    func respectsUser() {
        var chosen = segment([word("Mine", 0, 0.5)])
        chosen.speakerClusterID = b
        chosen.speakerAssignedByUser = true
        var edited = segment([word("Typo", 2, 2.5), word(" here", 2.5, 3)], text: "Fixed text")
        edited.editedAt = Date()

        let result = TranscriptSpeakerAligner.align([chosen, edited], to: timeline([(a, 0, 1), (b, 1, 2.6), (a, 2.6, 4)]))
        #expect(result[0] == chosen)
        #expect(result.count == 2, "edited text is never split")
        #expect(result[1].text == "Fixed text")
        #expect(result[1].speakerClusterID == b)
    }

    @Test("an empty timeline clears automatic attribution")
    func emptyTimeline() {
        var stale = segment([word("Hi", 0, 1)])
        stale.speakerClusterID = a
        stale.speakerIsUncertain = true
        let result = TranscriptSpeakerAligner.align([stale], to: .empty)
        #expect(result[0].speakerClusterID == nil)
        #expect(!result[0].speakerIsUncertain)
    }
}
