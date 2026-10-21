import ConversationCore
import ConversationML
import ConversationPipeline
import Foundation
import Testing

/// Unit vector with cosine `c` to axis 0, leaning toward `axis`.
private func voice(_ c: Double, toward axis: Int = 1) -> [Float] {
    var v = [Float](repeating: 0, count: 8)
    v[0] = Float(c)
    v[axis] = Float((1 - c * c).squareRoot())
    return v
}

private func axis(_ i: Int) -> [Float] {
    var v = [Float](repeating: 0, count: 8)
    v[i] = 1
    return v
}

@Suite("Speaker identity service (SPEC FR-5, FR-6)")
struct IdentityServiceTests {
    let store = TemporaryAudioFileStore()
    let engine = EngineDescriptor(identifier: "test.diarizer", version: "1")
    let source = EngineDescriptor(identifier: "live")

    /// A diarized recording: speaker "A" 0–10 s, speaker "B" 10–20 s, one
    /// window per turn with the given vectors, and one line per turn.
    private func seedRecording(
        _ repository: InMemoryRepository,
        a: [Float],
        b: [Float],
        state: ProcessingState = .ready
    ) async throws -> (recording: UUID, a: UUID, b: UUID) {
        let id = UUID()
        let url = try store.makeFileURL(forRecordingID: id, fileExtension: "caf")
        try Data([0]).write(to: url)
        try await repository.save(Recording(
            id: id, title: "R", duration: 20,
            audioFile: AudioFileReference(fileName: url.lastPathComponent, sampleRate: 48_000, channelCount: 1),
            recordingState: .completed, processingState: state, diarizationEngine: engine
        ))
        let clusterA = SpeakerCluster(recordingID: id, firstAppearance: 0)
        let clusterB = SpeakerCluster(recordingID: id, firstAppearance: 10)
        try await repository.replaceSpeakerTimeline(SpeakerTimeline(clusters: [clusterA, clusterB], turns: [
            SpeakerTurn(recordingID: id, clusterID: clusterA.id, timeRange: TimeRange(start: 0, end: 10)),
            SpeakerTurn(recordingID: id, clusterID: clusterB.id, timeRange: TimeRange(start: 10, end: 20)),
        ]), forRecording: id)
        try await repository.replaceVoiceData(RecordingVoiceData(engine: engine, windows: [
            WindowEmbedding(clusterID: clusterA.id, timeRange: TimeRange(start: 0, end: 10), vector: a),
            WindowEmbedding(clusterID: clusterB.id, timeRange: TimeRange(start: 10, end: 20), vector: b),
        ]), forRecording: id)
        try await repository.saveSegments([
            TranscriptSegment(recordingID: id, timeRange: TimeRange(start: 0, end: 10), text: "A talks", isFinal: true, source: source, speakerClusterID: clusterA.id),
            TranscriptSegment(recordingID: id, timeRange: TimeRange(start: 10, end: 20), text: "B talks", isFinal: true, source: source, speakerClusterID: clusterB.id),
        ])
        return (id, clusterA.id, clusterB.id)
    }

    private func service(_ repository: InMemoryRepository) -> IdentityService {
        IdentityService(recordings: repository, identity: repository, currentEngine: engine)
    }

    @Test("enrollment requires consent, a name, enough speech, and one consistent voice")
    func enrollmentGuards() async throws {
        let repository = InMemoryRepository()
        let r = try await seedRecording(repository, a: axis(0), b: axis(1))
        let identity = service(repository)
        let lines = [TimeRange(start: 0, end: 10)]

        await #expect(throws: IdentityError.consentRequired) {
            try await identity.enroll(recordingID: r.recording, clusterID: r.a, approvedRanges: lines, target: .newProfile(name: "Brett"), consentGiven: false)
        }
        await #expect(throws: IdentityError.emptyName) {
            try await identity.enroll(recordingID: r.recording, clusterID: r.a, approvedRanges: lines, target: .newProfile(name: "  "), consentGiven: true)
        }
        await #expect(throws: IdentityError.notEnoughSpeech(seconds: 3, required: 5)) {
            try await identity.enroll(recordingID: r.recording, clusterID: r.a, approvedRanges: [TimeRange(start: 0, end: 3)], target: .newProfile(name: "Brett"), consentGiven: true)
        }
        #expect(try await repository.speakerProfiles().isEmpty, "nothing saved by failed attempts")
    }

    @Test("a selection mixing voices is refused")
    func inconsistentSelection() async throws {
        let repository = InMemoryRepository()
        let r = try await seedRecording(repository, a: axis(0), b: axis(1))
        // Give cluster A a second, very different window.
        var voice = try #require(await repository.voiceData(forRecording: r.recording))
        voice.windows.append(WindowEmbedding(clusterID: r.a, timeRange: TimeRange(start: 5, end: 10), vector: axis(3)))
        try await repository.replaceVoiceData(voice, forRecording: r.recording)
        await #expect(throws: IdentityError.inconsistentSelection) {
            try await service(repository).enroll(recordingID: r.recording, clusterID: r.a, approvedRanges: [TimeRange(start: 0, end: 10)], target: .newProfile(name: "Brett"), consentGiven: true)
        }
    }

    @Test("an enrolled person is recognized in a separate recording; unknown speakers create no profile (SPEC Phase 3 exit)")
    func enrollAndRecognize() async throws {
        let repository = InMemoryRepository()
        let first = try await seedRecording(repository, a: axis(0), b: axis(1))
        let identity = service(repository)
        let brett = try await identity.enroll(
            recordingID: first.recording, clusterID: first.a,
            approvedRanges: [TimeRange(start: 0, end: 10)], target: .newProfile(name: "Brett"), consentGiven: true
        )
        #expect(try await repository.speakerProfiles().map(\.displayName) == ["Brett"])
        #expect(try await repository.voiceSamples(forProfile: brett.id).count == 1)
        #expect(try await identity.attribution(clusterID: first.a, recordingID: first.recording)?.status == .userConfirmed(profileID: brett.id))

        // A later recording: Brett at 0.9 (top tier), plus a stranger.
        let second = try await seedRecording(repository, a: voice(0.9, toward: 2), b: axis(4))
        try await identity.matchSpeakers(recordingID: second.recording)
        let names = try await identity.identifiedSpeakers(recordingID: second.recording)
        #expect(names[second.a]?.name == "Brett")
        #expect(names[second.a]?.needsVerification == false)
        #expect(names[second.b] == nil, "the stranger stays Speaker N")
        #expect(try await repository.speakerProfiles().count == 1, "no automatic enrollment")
        #expect(try await repository.voiceSamples(forProfile: nil).count == 1, "recognition never adds samples")

        let labels = SpeakerLabels.labels(forSegments: try await repository.segments(forRecording: second.recording),
                                          identified: names.mapValues(\.name))
        #expect(labels[second.a] == "Brett")
        #expect(labels[second.b] == "Speaker 1", "known speakers do not consume numbers")
    }

    @Test("verification tier: confirming records a positive example; rejecting records a negative one and is remembered")
    func confirmAndReject() async throws {
        let repository = InMemoryRepository()
        let first = try await seedRecording(repository, a: axis(0), b: axis(1))
        let identity = service(repository)
        let brett = try await identity.enroll(recordingID: first.recording, clusterID: first.a, approvedRanges: [TimeRange(start: 0, end: 10)], target: .newProfile(name: "Brett"), consentGiven: true)

        let second = try await seedRecording(repository, a: voice(0.78, toward: 2), b: axis(4))
        try await identity.matchSpeakers(recordingID: second.recording)
        #expect(try await identity.identifiedSpeakers(recordingID: second.recording)[second.a]?.needsVerification == true)
        #expect(try await repository.recording(id: second.recording)?.processingState == .needsReview)

        try await identity.confirm(clusterID: second.a, recordingID: second.recording)
        #expect(try await identity.attribution(clusterID: second.a, recordingID: second.recording)?.status == .userConfirmed(profileID: brett.id))
        #expect(try await repository.recording(id: second.recording)?.processingState == .ready)

        let third = try await seedRecording(repository, a: voice(0.75, toward: 3), b: axis(5))
        try await identity.matchSpeakers(recordingID: third.recording)
        try await identity.reject(clusterID: third.a, recordingID: third.recording)
        let rejected = try await identity.attribution(clusterID: third.a, recordingID: third.recording)
        #expect(rejected?.status == .unidentified)
        #expect(rejected?.rejectedProfileIDs == [brett.id])
        try await identity.rematchAll()
        #expect(try await identity.attribution(clusterID: third.a, recordingID: third.recording)?.status == .unidentified, "not suggested again")

        let feedback = try await repository.identityFeedback()
        #expect(feedback.map(\.isSameSpeaker) == [true, false])
        #expect(feedback.allSatisfy { $0.rawSimilarity > 0.7 && $0.rawSimilarity < 0.8 })
        let status = try await identity.calibrationStatus()
        #expect(!status.isCalibrated)
        #expect(status.confirmedMatches == 1 && status.rejectedMatches == 1)
    }

    @Test("manual assignment is a user override; a person can't be confirmed for two speakers in one recording")
    func assign() async throws {
        let repository = InMemoryRepository()
        let first = try await seedRecording(repository, a: axis(0), b: axis(1))
        let identity = service(repository)
        let brett = try await identity.enroll(recordingID: first.recording, clusterID: first.a, approvedRanges: [TimeRange(start: 0, end: 10)], target: .newProfile(name: "Brett"), consentGiven: true)

        // Low similarity, but the user says it is Brett.
        let second = try await seedRecording(repository, a: axis(6), b: axis(7))
        try await identity.assign(clusterID: second.a, recordingID: second.recording, profileID: brett.id)
        #expect(try await identity.attribution(clusterID: second.a, recordingID: second.recording)?.status == .userConfirmed(profileID: brett.id))
        await #expect(throws: IdentityError.alreadyAssigned(otherClusterID: second.a)) {
            try await identity.assign(clusterID: second.b, recordingID: second.recording, profileID: brett.id)
        }

        try await identity.keepUnidentified(clusterID: second.b, recordingID: second.recording)
        #expect(try await identity.attribution(clusterID: second.b, recordingID: second.recording)?.status == .userKeptUnidentified)
        try await identity.clearDecision(clusterID: second.b, recordingID: second.recording)
        #expect(try await identity.attribution(clusterID: second.b, recordingID: second.recording)?.status == .unidentified)
    }

    @Test("adding a sample to an existing person only happens explicitly and improves later matches")
    func addSample() async throws {
        let repository = InMemoryRepository()
        let first = try await seedRecording(repository, a: axis(0), b: axis(1))
        let identity = service(repository)
        let brett = try await identity.enroll(recordingID: first.recording, clusterID: first.a, approvedRanges: [TimeRange(start: 0, end: 10)], target: .newProfile(name: "Brett"), consentGiven: true)

        let second = try await seedRecording(repository, a: voice(0.6, toward: 2), b: axis(4))
        try await identity.matchSpeakers(recordingID: second.recording)
        #expect(try await identity.identifiedSpeakers(recordingID: second.recording)[second.a] == nil, "0.6 is below the verification tier")

        try await identity.enroll(recordingID: second.recording, clusterID: second.a, approvedRanges: [TimeRange(start: 0, end: 10)], target: .existingProfile(brett.id), consentGiven: true)
        #expect(try await repository.voiceSamples(forProfile: brett.id).count == 2)
        let feedback = try await repository.identityFeedback()
        #expect(feedback.count == 1, "one example, scored before the new sample existed")
        #expect(abs((feedback.first?.rawSimilarity ?? 0) - 0.6) < 1e-6)
        let summary = try #require(try await identity.profileSummaries().first)
        #expect(summary.compatibleSampleCount == 2)
        #expect(summary.recordingCount == 2)
        #expect(summary.enrolledSeconds == 20)
    }

    @Test("deleting a person removes their data and reverts every recording to numbered speakers")
    func deleteProfile() async throws {
        let repository = InMemoryRepository()
        let first = try await seedRecording(repository, a: axis(0), b: axis(1))
        let identity = service(repository)
        let brett = try await identity.enroll(recordingID: first.recording, clusterID: first.a, approvedRanges: [TimeRange(start: 0, end: 10)], target: .newProfile(name: "Brett"), consentGiven: true)
        let second = try await seedRecording(repository, a: voice(0.78, toward: 2), b: axis(4))
        try await identity.matchSpeakers(recordingID: second.recording)
        try await identity.confirm(clusterID: second.a, recordingID: second.recording)

        try await identity.deleteProfile(id: brett.id)
        #expect(try await repository.speakerProfiles().isEmpty)
        #expect(try await repository.voiceSamples(forProfile: nil).isEmpty)
        #expect(try await repository.identityFeedback().isEmpty)
        #expect(try await identity.identifiedSpeakers(recordingID: first.recording).isEmpty)
        #expect(try await identity.identifiedSpeakers(recordingID: second.recording).isEmpty)
        #expect(try await identity.attribution(clusterID: second.a, recordingID: second.recording)?.status == .unidentified)
    }

    @Test("merging speakers moves voice windows and carries a user's identity decision")
    func mergeCarriesDecision() async throws {
        let repository = InMemoryRepository()
        let first = try await seedRecording(repository, a: axis(0), b: axis(1))
        let identity = service(repository)
        let brett = try await identity.enroll(recordingID: first.recording, clusterID: first.a, approvedRanges: [TimeRange(start: 0, end: 10)], target: .newProfile(name: "Brett"), consentGiven: true)

        let editor = SpeakerEditor(repository: repository, identity: repository)
        try await editor.merge(cluster: first.a, into: first.b, inRecording: first.recording)
        #expect(try await repository.voiceData(forRecording: first.recording)?.windows.allSatisfy { $0.clusterID == first.b } == true)
        #expect(try await identity.attribution(clusterID: first.b, recordingID: first.recording)?.status == .userConfirmed(profileID: brett.id))
        #expect(try await identity.attribution(clusterID: first.a, recordingID: first.recording) == nil)
    }

    @Test("processing runs identity matching after diarization and flags verification for review")
    func processingIntegration() async throws {
        let repository = InMemoryRepository()
        let first = try await seedRecording(repository, a: axis(0), b: axis(1))
        let identity = service(repository)
        let brett = try await identity.enroll(recordingID: first.recording, clusterID: first.a, approvedRanges: [TimeRange(start: 0, end: 10)], target: .newProfile(name: "Brett"), consentGiven: true)

        // A fresh recording with word-timed text, processed end to end.
        let id = UUID()
        let url = try store.makeFileURL(forRecordingID: id, fileExtension: "caf")
        try Data([0]).write(to: url)
        try await repository.save(Recording(id: id, title: "New", duration: 20,
            audioFile: AudioFileReference(fileName: url.lastPathComponent, sampleRate: 48_000, channelCount: 1), recordingState: .completed))
        try await repository.saveSegments([
            TranscriptSegment(recordingID: id, timeRange: TimeRange(start: 0, end: 9), text: "Hi", isFinal: true, source: source,
                              words: [TimedWord(text: "Hi", timeRange: TimeRange(start: 0, end: 9))]),
            TranscriptSegment(recordingID: id, timeRange: TimeRange(start: 11, end: 19), text: "Hello", isFinal: true, source: source,
                              words: [TimedWord(text: "Hello", timeRange: TimeRange(start: 11, end: 19))]),
        ])
        let diarizer = FakeDiarizer(.voices([(0, 0, 10), (1, 10, 20)], vectors: [0: voice(0.78, toward: 3), 1: axis(5)]))
        let coordinator = PostProcessingCoordinator(
            repository: repository, audioFileStore: store, retranscription: nil, diarizer: diarizer,
            identityRepository: repository, identity: identity
        )
        let outcome = try await coordinator.process(recordingID: id)
        #expect(outcome == .needsReview, "Brett at 0.78 needs verification")
        #expect(try await repository.voiceData(forRecording: id)?.windows.count == 2)
        let names = try await identity.identifiedSpeakers(recordingID: id)
        #expect(names.values.map(\.profileID) == [brett.id])

        // Confirm, then re-run with the stored diarization: the decision survives.
        let clusterID = try #require(names.keys.first)
        try await identity.confirm(clusterID: clusterID, recordingID: id)
        #expect(try await coordinator.process(recordingID: id) == .ready)
        #expect(try await identity.attribution(clusterID: clusterID, recordingID: id)?.status == .userConfirmed(profileID: brett.id))

        // A recording diarized before voice data existed is diarized again.
        try await repository.replaceVoiceData(nil, forRecording: id)
        try await repository.replaceSpeakerAttributions([], forRecording: id)
        let callsBefore = diarizer.calls
        try await coordinator.process(recordingID: id)
        #expect(diarizer.calls == callsBefore + 1)
        #expect(try await repository.voiceData(forRecording: id) != nil)
        let reconfirm = try #require(try await identity.identifiedSpeakers(recordingID: id).keys.first)
        try await identity.confirm(clusterID: reconfirm, recordingID: id)

        // A fresh diarization would invent new clusters: it must ask first.
        await #expect(throws: PostProcessingError.wouldDiscardSpeakerCorrections(count: 1)) {
            try await coordinator.process(recordingID: id, reuseExistingDiarization: false)
        }
    }
}
