import ConversationCore
import Foundation
import Testing

/// A unit vector whose cosine with axis 0 is `c`, leaning toward `axis`.
func voice(_ c: Double, toward axis: Int = 1, dimensions: Int = 8) -> [Float] {
    var v = [Float](repeating: 0, count: dimensions)
    v[0] = Float(c)
    v[axis] = Float((1 - c * c).squareRoot())
    return v
}

func axisVector(_ axis: Int, dimensions: Int = 8) -> [Float] {
    var v = [Float](repeating: 0, count: dimensions)
    v[axis] = 1
    return v
}

@Suite("Vector math and voiceprints")
struct VoiceprintTests {
    @Test("cosine, centroid, and binary encoding")
    func math() {
        #expect(abs(VectorMath.cosine([1, 0], [0, 1])) < 1e-9)
        #expect(abs(VectorMath.cosine([2, 0], [5, 0]) - 1) < 1e-9)
        #expect(VectorMath.cosine([1], [1, 0]) == 0, "mismatched sizes")
        let centroid = try? #require(VectorMath.centroid([[1, 0], [0, 1]]))
        #expect(abs((centroid?[0] ?? 0) - Float(0.5).squareRoot()) < 1e-6)
        let vector: [Float] = [0.25, -1.5, 3, .pi]
        #expect(VectorMath.decode(VectorMath.encode(vector)) == vector)
    }

    @Test("cluster voiceprints report consistency and clean, non-overlapping speech")
    func clusterVoiceprint() throws {
        let recording = UUID()
        let a = SpeakerCluster(recordingID: recording, firstAppearance: 0)
        let b = SpeakerCluster(recordingID: recording, firstAppearance: 5)
        let timeline = SpeakerTimeline(clusters: [a, b], turns: [
            SpeakerTurn(recordingID: recording, clusterID: a.id, timeRange: TimeRange(start: 0, end: 6)),
            SpeakerTurn(recordingID: recording, clusterID: b.id, timeRange: TimeRange(start: 5, end: 10)),
            SpeakerTurn(recordingID: recording, clusterID: a.id, timeRange: TimeRange(start: 12, end: 14), isUncertain: true),
        ])
        let engine = EngineDescriptor(identifier: "e")
        let data = RecordingVoiceData(engine: engine, windows: [
            WindowEmbedding(clusterID: a.id, timeRange: TimeRange(start: 0, end: 10), vector: axisVector(0)),
            WindowEmbedding(clusterID: a.id, timeRange: TimeRange(start: 10, end: 20), vector: axisVector(0)),
            WindowEmbedding(clusterID: b.id, timeRange: TimeRange(start: 0, end: 10), vector: axisVector(1)),
            WindowEmbedding(clusterID: b.id, timeRange: TimeRange(start: 10, end: 20), vector: axisVector(2)),
        ])
        let prints = ClusterVoiceprint.make(from: data, timeline: timeline)
        let printA = try #require(prints.first { $0.clusterID == a.id })
        let printB = try #require(prints.first { $0.clusterID == b.id })
        #expect(abs(printA.consistency - 1) < 1e-6)
        #expect(printB.consistency < 0.8, "two orthogonal windows mean a mixed cluster")
        #expect(abs(printA.cleanSpeechSeconds - 5) < 1e-9, "overlap and uncertain turns excluded")
        #expect(abs(printB.cleanSpeechSeconds - 4) < 1e-9)
        #expect(printA.windowCount == 2)
    }
}

@Suite("Identity matching policy (SPEC FR-5, provisional thresholds)")
struct IdentityMatcherTests {
    let recording = UUID()
    let engine = EngineDescriptor(identifier: "e", version: "1")
    let brett = UUID()
    let alex = UUID()

    private func cluster(_ vector: [Float], id: UUID = UUID(), consistency: Double = 0.95, speech: Double = 10) -> ClusterVoiceprint {
        ClusterVoiceprint(clusterID: id, engine: engine, vector: vector, windowCount: 3, consistency: consistency, cleanSpeechSeconds: speech)
    }

    private func decide(
        _ clusters: [ClusterVoiceprint],
        profiles: [(UUID, [Float])],
        existing: [SpeakerAttribution] = [],
        policy: IdentityMatchingPolicy = .provisional
    ) -> [UUID: SpeakerAttribution] {
        let result = IdentityMatcher.decide(
            recordingID: recording,
            voiceprints: clusters,
            profiles: profiles.map { ProfileVoiceprint(profileID: $0.0, vector: $0.1, sampleCount: 1) },
            existing: Dictionary(existing.map { ($0.clusterID, $0) }, uniquingKeysWith: { a, _ in a }),
            policy: policy
        )
        return Dictionary(result.map { ($0.clusterID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    @Test("provisional tiers: ≥0.85 recognized, ≥0.70 needs verification, below stays Speaker N")
    func tiers() {
        let high = cluster(voice(0.9)), mid = cluster(voice(0.8)), low = cluster(voice(0.5))
        for (print, expected) in [(high, SpeakerAttributionStatus.recognized(profileID: brett)),
                                  (mid, .needsVerification(profileID: brett)),
                                  (low, .unidentified)] {
            let result = decide([print], profiles: [(brett, axisVector(0))])
            #expect(result[print.clusterID]?.status == expected)
            #expect(result[print.clusterID]?.evidence?.calibratedConfidence == nil, "no probability while provisional")
        }
        let lowEvidence = decide([low], profiles: [(brett, axisVector(0))])[low.clusterID]?.evidence
        #expect(lowEvidence?.bestProfileID == brett)
        #expect(abs((lowEvidence?.rawSimilarity ?? 0) - 0.5) < 1e-6)
    }

    @Test("quality gates beat a high score (SPEC scenario 9)")
    func gates() {
        let short = cluster(voice(0.99), speech: 2)
        let mixed = cluster(voice(0.99), consistency: 0.8)
        let result = decide([short, mixed], profiles: [(brett, axisVector(0))])
        #expect(result[short.clusterID]?.status == .unidentified)
        #expect(result[short.clusterID]?.evidence?.issues.contains(.tooLittleSpeech) == true)
        #expect(result[mixed.clusterID]?.status == .unidentified)
        #expect(result[mixed.clusterID]?.evidence?.issues.contains(.inconsistentVoice) == true)
    }

    @Test("two people scoring close together leaves the speaker unidentified")
    func margin() {
        // Brett on axis 0, Alex close to Brett; the speaker sits between them.
        let speaker = cluster(VectorMath.normalized([1, 0.9, 0, 0, 0, 0, 0, 0]))
        let result = decide([speaker], profiles: [(brett, axisVector(0)), (alex, axisVector(1))])
        #expect(result[speaker.clusterID]?.status == .unidentified)
        #expect(result[speaker.clusterID]?.evidence?.issues.contains(.ambiguousBetweenPeople) == true)
    }

    @Test("one person per recording: the stronger claim wins")
    func oneToOne() {
        let strong = cluster(voice(0.95)), weaker = cluster(voice(0.88, toward: 2))
        let result = decide([strong, weaker], profiles: [(brett, axisVector(0))])
        #expect(result[strong.clusterID]?.status == .recognized(profileID: brett))
        #expect(result[weaker.clusterID]?.status == .unidentified)
    }

    @Test("a speaker that loses its best person falls back only to the verification tier")
    func fallbackNeverTopTier() {
        // Brett = e0; Alex has cosine 0.5 with Brett.
        let alexVoice: [Float] = [0.5, 0.866, 0, 0, 0, 0, 0, 0]
        let strong = cluster(voice(0.97, toward: 2))             // Brett 0.97, Alex 0.49
        let other = cluster([0.88, 0.475, 0, 0, 0, 0, 0, 0])    // Brett 0.88, Alex 0.85
        #expect(VectorMath.cosine(other.vector, alexVoice) >= IdentityMatchingPolicy.provisional.provisionalRecognitionSimilarity)
        var policy = IdentityMatchingPolicy.provisional
        policy.minimumMargin = 0
        let result = decide([strong, other], profiles: [(brett, axisVector(0)), (alex, alexVoice)], policy: policy)
        #expect(result[strong.clusterID]?.status == .recognized(profileID: brett))
        #expect(result[other.clusterID]?.status == .needsVerification(profileID: alex),
                "a top-tier score for a fallback person is held to the verification tier")
    }

    @Test("rejected people are not suggested again; user decisions are never overwritten")
    func userDecisions() {
        let rejecting = cluster(voice(0.95))
        let rejected = SpeakerAttribution(clusterID: rejecting.clusterID, recordingID: recording, status: .unidentified, rejectedProfileIDs: [brett])
        #expect(decide([rejecting], profiles: [(brett, axisVector(0))], existing: [rejected])[rejecting.clusterID]?.status == .unidentified)

        let kept = cluster(voice(0.95))
        let keptDecision = SpeakerAttribution(clusterID: kept.clusterID, recordingID: recording, status: .userKeptUnidentified)
        #expect(decide([kept], profiles: [(brett, axisVector(0))], existing: [keptDecision])[kept.clusterID]?.status == .userKeptUnidentified)

        // Brett confirmed by the user on one speaker is not claimed by another.
        let confirmed = cluster(voice(0.1))
        let other = cluster(voice(0.95))
        let confirmation = SpeakerAttribution(clusterID: confirmed.clusterID, recordingID: recording, status: .userConfirmed(profileID: brett))
        let result = decide([confirmed, other], profiles: [(brett, axisVector(0))], existing: [confirmation])
        #expect(result[confirmed.clusterID]?.status == .userConfirmed(profileID: brett))
        #expect(result[other.clusterID]?.status == .unidentified)
    }

    @Test("with a validated calibration, the SPEC's 60% / 80% tiers apply to calibrated confidence")
    func calibratedMode() {
        // confidence = sigmoid(10 * s - 4): s=0.45 → ~0.62, s=0.6 → ~0.88
        let calibration = IdentityCalibration(slope: 10, intercept: -4, engine: engine, positiveCount: 40, negativeCount: 40, expectedCalibrationError: 0.02)
        let policy = IdentityMatchingPolicy(calibration: calibration)
        #expect(policy.isCalibrated)
        let mid = cluster(voice(0.45)), high = cluster(voice(0.6))
        let result = decide([mid, high], profiles: [(brett, axisVector(0)), (alex, axisVector(5))], policy: policy)
        #expect(result[mid.clusterID]?.status == .needsVerification(profileID: brett) || result[high.clusterID]?.status == .recognized(profileID: brett))
        #expect(result[high.clusterID]?.status == .recognized(profileID: brett))
        #expect((result[high.clusterID]?.evidence?.calibratedConfidence ?? 0) > 0.8)

        let unvalidated = IdentityCalibration(slope: 10, intercept: -4, engine: engine, positiveCount: 5, negativeCount: 40, expectedCalibrationError: 0.02)
        #expect(!IdentityMatchingPolicy(calibration: unvalidated).isCalibrated, "too few positives")
    }
}

@Suite("Calibration fitting")
struct CalibrationTests {
    let engine = EngineDescriptor(identifier: "e")

    /// Deterministic data where P(match | score) rises with score.
    private func examples() -> [CalibrationFitting.Example] {
        (0..<200).map { i in
            let score = Double(i) / 200
            // Matches are frequent above 0.6, rare below 0.4, mixed between.
            let isMatch = score > 0.6 ? i % 10 != 0 : (score < 0.4 ? i % 10 == 0 : i % 2 == 0)
            return CalibrationFitting.Example(score: score, isMatch: isMatch)
        }
    }

    @Test("Platt fit is increasing and maps low scores low and high scores high")
    func fit() throws {
        let model = try #require(CalibrationFitting.fitPlatt(examples()))
        #expect(model.slope > 0)
        let calibration = IdentityCalibration(slope: model.slope, intercept: model.intercept, engine: engine, positiveCount: 0, negativeCount: 0, expectedCalibrationError: 0)
        #expect(calibration.confidence(forRawSimilarity: 0.1) < 0.3)
        #expect(calibration.confidence(forRawSimilarity: 0.9) > 0.7)
    }

    @Test("a single class cannot be calibrated")
    func oneClass() {
        #expect(CalibrationFitting.fitPlatt([.init(score: 0.9, isMatch: true), .init(score: 0.8, isMatch: true)]) == nil)
    }

    @Test("ECE is zero for perfectly calibrated bins and large for overconfident ones")
    func ece() {
        let perfect = CalibrationFitting.expectedCalibrationError(
            probabilities: [0.25, 0.25, 0.25, 0.25], labels: [true, false, false, false], bins: 4)
        #expect(perfect < 1e-9)
        let overconfident = CalibrationFitting.expectedCalibrationError(
            probabilities: [0.95, 0.95, 0.95, 0.95], labels: [true, false, false, false], bins: 10)
        #expect(overconfident > 0.6)
    }

    @Test("cross-validated calibration reports counts and held-out error")
    func calibrate() throws {
        let calibration = try #require(CalibrationFitting.calibrate(examples(), engine: engine))
        #expect(calibration.positiveCount + calibration.negativeCount == 200)
        #expect(calibration.positiveCount >= IdentityCalibration.minimumExamplesPerClass)
        #expect(calibration.expectedCalibrationError < 0.15)
    }
}
