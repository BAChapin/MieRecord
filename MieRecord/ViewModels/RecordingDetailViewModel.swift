import ConversationCore
import ConversationPipeline
import Foundation
import Observation

/// One speaker present in the transcript, in label order.
struct SpeakerOption: Identifiable, Equatable {
    let id: UUID
    /// A known person's name, or `Speaker N`.
    let label: String
    /// Position in first-appearance order; drives the speaker's color.
    let index: Int
    /// Set when the speaker is matched or assigned to a known person.
    var person: IdentifiedSpeaker?
    /// Whether voice data exists, so the voice can be enrolled.
    var hasVoiceprint: Bool = false

    var needsVerification: Bool { person?.needsVerification == true }
}

/// What the enrollment sheet is doing.
struct EnrollmentRequest: Identifiable {
    enum Target: Equatable {
        case newPerson
        case existing(profileID: UUID, name: String)
    }

    let speaker: SpeakerOption
    let target: Target
    var id: UUID { speaker.id }
}

@Observable
final class RecordingDetailViewModel {
    private(set) var recording: Recording
    private(set) var segments: [TranscriptSegment] = []
    /// Labels for clusters that own text, recomputed after every change.
    private(set) var speakers: [SpeakerOption] = []
    /// Everyone in the library, for "This is…" menus.
    private(set) var people: [SpeakerProfile] = []
    var enrollment: EnrollmentRequest?
    var errorMessage: String?
    let playback = AudioPlaybackController()

    private let dependencies: AppDependencies

    init(recording: Recording, dependencies: AppDependencies) {
        self.recording = recording
        self.dependencies = dependencies
    }

    var audioURL: URL { dependencies.audioFileStore.url(for: recording.audioFile) }
    var jobs: ProcessingJobs { dependencies.processingJobs }
    var jobStatus: ProcessingJobs.Status? { jobs.status[recording.id] }
    var isBusy: Bool { jobs.isRunning(recording.id) }
    var canIdentifySpeakers: Bool { jobs.canIdentifySpeakers }

    /// Speakers have been assigned at least once.
    var hasSpeakers: Bool { !speakers.isEmpty }
    var hasCorrections: Bool { segments.contains(where: \.speakerAssignedByUser) }
    var hasTextOrSpeakerEdits: Bool { segments.contains(where: \.hasUserEdits) }
    var reviewLineCount: Int { hasSpeakers ? segments.filter { $0.speakerIsUncertain || $0.speakerClusterID == nil }.count : 0 }
    var verificationCount: Int { speakers.filter(\.needsVerification).count }
    var reviewCount: Int { reviewLineCount + verificationCount }

    /// The latest failure: this session's job error, or one persisted earlier.
    var failureMessage: String? {
        if let error = jobs.errors[recording.id] { return error }
        if case let .failed(failure) = recording.processingState { return failure.message }
        return nil
    }

    func speaker(for segment: TranscriptSegment) -> SpeakerOption? {
        guard let id = segment.speakerClusterID else { return nil }
        return speakers.first { $0.id == id }
    }

    // MARK: - Loading

    func load() async {
        playback.load(url: audioURL)
        await reloadTranscript()
    }

    /// Reloads the recording and transcript without touching playback.
    func reloadTranscript() async {
        do {
            if let latest = try await dependencies.repository.recording(id: recording.id) {
                recording = latest
            }
            segments = try await dependencies.repository.segments(forRecording: recording.id)
            let identified = try await dependencies.identity.identifiedSpeakers(recordingID: recording.id)
            let withVoice = try await dependencies.identity.clustersWithVoiceprints(recordingID: recording.id)
            speakers = Self.speakerOptions(for: segments, identified: identified, withVoice: withVoice)
            people = try await dependencies.identity.profileSummaries().map(\.profile)
        } catch {
            errorMessage = "Could not load the transcript: \(error.localizedDescription)"
        }
    }

    static func speakerOptions(
        for segments: [TranscriptSegment],
        identified: [UUID: IdentifiedSpeaker],
        withVoice: Set<UUID>
    ) -> [SpeakerOption] {
        let labels = SpeakerLabels.labels(forSegments: segments, identified: identified.mapValues(\.name))
        var order: [UUID] = []
        for segment in segments.sortedByTime() {
            if let id = segment.speakerClusterID, labels[id] != nil, !order.contains(id) {
                order.append(id)
            }
        }
        return order.enumerated().compactMap { index, id in
            labels[id].map {
                SpeakerOption(id: id, label: $0, index: index, person: identified[id], hasVoiceprint: withVoice.contains(id))
            }
        }
    }

    // MARK: - Jobs

    func retranscribe() {
        jobs.retranscribe(recording.id, discardingCorrections: hasTextOrSpeakerEdits)
    }

    /// - Parameter fresh: detect speakers again rather than reuse the last result.
    func identifySpeakers(fresh: Bool) {
        jobs.identifySpeakers(recording.id, discardingCorrections: hasCorrections, fresh: fresh)
    }

    func retryLastJob() {
        switch jobs.lastKind[recording.id] {
        case .retranscribe?: retranscribe()
        case .identifySpeakers?, nil:
            if canIdentifySpeakers { identifySpeakers(fresh: false) } else { retranscribe() }
        }
    }

    func cancelJob() {
        jobs.cancel(recording.id)
    }

    // MARK: - Speaker corrections

    func move(_ segment: TranscriptSegment, to speaker: SpeakerOption) async {
        await edit { try await $0.assign(segmentID: segment.id, inRecording: self.recording.id, toCluster: speaker.id) }
    }

    func moveToNewSpeaker(_ segment: TranscriptSegment) async {
        await edit { try await $0.assignToNewSpeaker(segmentID: segment.id, inRecording: self.recording.id) }
    }

    func confirm(_ segment: TranscriptSegment) async {
        await edit { try await $0.confirm(segmentID: segment.id, inRecording: self.recording.id) }
    }

    func merge(_ source: SpeakerOption, into target: SpeakerOption) async {
        await edit { try await $0.merge(cluster: source.id, into: target.id, inRecording: self.recording.id) }
    }

    private func edit(_ change: (SpeakerEditor) async throws -> Void) async {
        guard !isBusy else { return }
        do {
            try await change(dependencies.speakerEditor)
            // Voiceprints may have moved between speakers; match again.
            try await dependencies.identity.matchSpeakers(recordingID: recording.id)
            await reloadTranscript()
            jobs.noteDataChanged()
        } catch {
            errorMessage = "Could not change the speaker: \(error.localizedDescription)"
        }
    }

    // MARK: - Identity

    /// "Yes, this is <person>" for a suggested match.
    func confirmIdentity(_ speaker: SpeakerOption) async {
        await identityAction { try await $0.confirm(clusterID: speaker.id, recordingID: self.recording.id) }
    }

    /// "Not <person>": rejects the suggestion and remembers it.
    func rejectIdentity(_ speaker: SpeakerOption) async {
        await identityAction { try await $0.reject(clusterID: speaker.id, recordingID: self.recording.id) }
    }

    /// "This is <person>": a user override. If that person is already confirmed
    /// for another speaker here, the two speakers are the same person and are merged.
    func assign(_ speaker: SpeakerOption, to person: SpeakerProfile) async {
        guard !isBusy else { return }
        do {
            try await dependencies.identity.assign(clusterID: speaker.id, recordingID: recording.id, profileID: person.id)
        } catch IdentityError.alreadyAssigned(let otherClusterID) {
            if let other = speakers.first(where: { $0.id == otherClusterID }) {
                await merge(speaker, into: other)
                return
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await reloadTranscript()
        jobs.noteDataChanged()
    }

    func keepUnidentified(_ speaker: SpeakerOption) async {
        await identityAction { try await $0.keepUnidentified(clusterID: speaker.id, recordingID: self.recording.id) }
    }

    /// Returns the speaker to automatic matching.
    func clearIdentity(_ speaker: SpeakerOption) async {
        await identityAction { try await $0.clearDecision(clusterID: speaker.id, recordingID: self.recording.id) }
    }

    func startEnrollment(_ speaker: SpeakerOption, target: EnrollmentRequest.Target) {
        enrollment = EnrollmentRequest(speaker: speaker, target: target)
    }

    /// Lines that can be offered for enrollment: this speaker's, not flagged.
    func enrollableLines(for speaker: SpeakerOption) -> [TranscriptSegment] {
        segments.filter { $0.speakerClusterID == speaker.id && !$0.speakerIsUncertain && $0.timeRange != nil }
    }

    /// Saves a voice. Returns an error message to show in the sheet, or nil.
    func enroll(_ request: EnrollmentRequest, name: String, lines: [TranscriptSegment], consent: Bool) async -> String? {
        let target: IdentityService.EnrollmentTarget = switch request.target {
        case .newPerson: .newProfile(name: name)
        case let .existing(profileID, _): .existingProfile(profileID)
        }
        do {
            try await dependencies.identity.enroll(
                recordingID: recording.id,
                clusterID: request.speaker.id,
                approvedRanges: lines.compactMap(\.timeRange),
                target: target,
                consentGiven: consent
            )
            enrollment = nil
            await reloadTranscript()
            jobs.noteDataChanged()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func identityAction(_ action: (IdentityService) async throws -> Void) async {
        guard !isBusy else { return }
        do {
            try await action(dependencies.identity)
            await reloadTranscript()
            jobs.noteDataChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Other

    func rename(to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != recording.title else { return }
        do {
            // Atomic update so a running job's state isn't overwritten by this
            // screen's possibly stale copy.
            recording = try await dependencies.repository.updateRecording(id: recording.id) { $0.title = trimmed }
            jobs.noteDataChanged()
        } catch {
            errorMessage = "Could not rename: \(error.localizedDescription)"
        }
    }

    /// The segment under the playhead, if any.
    var currentSegmentID: UUID? {
        let time = playback.currentTime
        return segments.first { $0.timeRange?.contains(time) == true }?.id
    }

    func unload() {
        playback.unload()
    }
}
