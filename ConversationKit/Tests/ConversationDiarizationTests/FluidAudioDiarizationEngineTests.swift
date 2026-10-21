import ConversationCore
import ConversationML
import Foundation
import Testing
@testable import ConversationDiarization

/// The bundled models live in the repository, outside the package.
private let repositoryModels = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ConversationDiarizationTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // ConversationKit
    .deletingLastPathComponent() // repository root
    .appending(path: "Models/DiarizationModels", directoryHint: .isDirectory)

private let modelsPresent = FluidAudioDiarizationEngine.missingModelsReason(in: repositoryModels) == nil

@Suite("FluidAudio diarization adapter")
struct FluidAudioDiarizationEngineTests {
    @Test("engine speaker IDs map to fresh, recording-owned clusters ordered by first appearance")
    func mapping() {
        let recording = UUID()
        let timeline = FluidAudioDiarizationEngine.timeline(from: [
            (speaker: "S2", start: 0, end: 2),
            (speaker: "S1", start: 2.5, end: 4),
            (speaker: "S2", start: 4.5, end: 6),
            (speaker: "S3", start: 7, end: 7), // zero length is dropped
        ], recordingID: recording)

        #expect(timeline.clusters.count == 2)
        #expect(timeline.turns.count == 3)
        #expect(timeline.clusters.map(\.firstAppearance) == [0, 2.5])
        #expect(timeline.turns[0].clusterID == timeline.turns[2].clusterID)
        #expect(timeline.turns[0].clusterID != timeline.turns[1].clusterID)
        #expect(timeline.clusters.allSatisfy { $0.recordingID == recording })
        #expect(timeline.turns.allSatisfy { $0.recordingID == recording })
    }

    @Test("a build without models reports unsupported instead of downloading")
    func missingModels() async throws {
        let engine = FluidAudioDiarizationEngine(modelsDirectory: nil)
        guard case .unsupported = await engine.availability() else {
            Issue.record("expected unsupported"); return
        }
        let empty = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let partial = FluidAudioDiarizationEngine(modelsDirectory: empty)
        await #expect(throws: DiarizationError.self) { try await partial.prepare() }
    }

    @Test(
        "the bundled models separate three voices offline and find each turn",
        .enabled(if: modelsPresent, "bundled models not found at Models/DiarizationModels")
    )
    func endToEnd() async throws {
        let audio = try #require(Bundle.module.url(forResource: "three-voice-meeting", withExtension: "m4a", subdirectory: "Fixtures"))
        let engine = FluidAudioDiarizationEngine(modelsDirectory: repositoryModels)
        #expect(await engine.availability() == .available)

        let recording = UUID()
        let output = try await engine.diarize(audioURL: audio, recordingID: recording) { _ in }
        let timeline = output.timeline

        #expect(timeline.clusters.count == 3)
        // Ground truth from Fixtures/README.md: line → voice index.
        let truth: [(start: Double, end: Double, voice: Int)] = [
            (0.00, 3.89, 0), (4.49, 9.20, 1), (9.80, 14.99, 2),
            (15.59, 19.72, 0), (20.32, 24.54, 1), (25.14, 29.85, 2), (30.45, 34.07, 0),
        ]
        // Each line must be mostly covered by turns of one dominant cluster
        // (a line may be split at a pause), lines by the same voice must share
        // a cluster, and different voices must not.
        var clusterForVoice: [Int: UUID] = [:]
        for line in truth {
            let range = TimeRange(start: line.start, end: line.end)
            var overlap: [UUID: Double] = [:]
            for turn in timeline.turns {
                let seconds = min(turn.timeRange.end, range.end) - max(turn.timeRange.start, range.start)
                if seconds > 0 { overlap[turn.clusterID, default: 0] += seconds }
            }
            let dominant = try #require(overlap.max { $0.value < $1.value }, "no turn overlaps line at \(line.start)s")
            #expect(dominant.value / range.duration > 0.7, "line at \(line.start)s only \(Int(dominant.value / range.duration * 100))% covered")
            if let expected = clusterForVoice[line.voice] {
                #expect(dominant.key == expected, "line at \(line.start)s changed cluster")
            } else {
                #expect(!clusterForVoice.values.contains(dominant.key), "two voices share a cluster")
                clusterForVoice[line.voice] = dominant.key
            }
        }
        // Speaker numbering follows first appearance: Samantha is Speaker 1.
        let labels = SpeakerLabels.labels(for: timeline.clusters)
        #expect(labels[try #require(clusterForVoice[0])] == "Speaker 1")
        #expect(labels[try #require(clusterForVoice[1])] == "Speaker 2")
        #expect(labels[try #require(clusterForVoice[2])] == "Speaker 3")

        // Voiceprints for identity matching: every speaker has 256-d window
        // embeddings, each speaker is internally consistent, and different
        // voices are far apart.
        let voice = try #require(output.voiceData)
        #expect(voice.engine == engine.descriptor)
        #expect(voice.windows.allSatisfy { $0.vector.count == 256 })
        let prints = ClusterVoiceprint.make(from: voice, timeline: timeline)
        #expect(prints.count == 3)
        #expect(prints.allSatisfy { $0.consistency >= IdentityMatchingPolicy.provisional.minimumConsistency })
        for a in prints {
            for b in prints where a.clusterID != b.clusterID {
                #expect(VectorMath.cosine(a.vector, b.vector) < IdentityMatchingPolicy.provisional.provisionalVerificationSimilarity)
            }
        }
    }

    @Test("window embeddings attach to the same clusters as turns; bad windows are dropped")
    func outputMapping() {
        let recording = UUID()
        let engine = EngineDescriptor(identifier: "e")
        let output = FluidAudioDiarizationEngine.output(
            segments: [(speaker: "S1", start: 0, end: 2), (speaker: "S2", start: 2, end: 4)],
            windows: [
                (speaker: "S1", start: 0, end: 10, vector: [1, 0]),
                (speaker: "S2", start: 0, end: 10, vector: [0, 1]),
                (speaker: "S9", start: 0, end: 10, vector: [1, 1]),      // no turns
                (speaker: "S1", start: 10, end: 20, vector: [.nan, 1]),  // not finite
            ],
            recordingID: recording,
            engine: engine
        )
        let windows = try? #require(output.voiceData?.windows)
        #expect(windows?.count == 2)
        let s1 = output.timeline.turns[0].clusterID
        let s2 = output.timeline.turns[1].clusterID
        #expect(windows?.first { $0.vector == [1, 0] }?.clusterID == s1)
        #expect(windows?.first { $0.vector == [0, 1] }?.clusterID == s2)
    }
}
