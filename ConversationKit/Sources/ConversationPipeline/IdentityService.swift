import ConversationCore
import Foundation
import OSLog

public enum IdentityError: Error, Equatable, Sendable, LocalizedError {
    case consentRequired
    case emptyName
    case notEnoughSpeech(seconds: Double, required: Double)
    case noVoiceprint
    case inconsistentSelection
    case profileNotFound
    case clusterNotFound
    /// The person is already confirmed for another speaker in this recording.
    case alreadyAssigned(otherClusterID: UUID)

    public var errorDescription: String? {
        switch self {
        case .consentRequired: "Saving a voice requires confirming you have the person's permission."
        case .emptyName: "Enter a name."
        case let .notEnoughSpeech(seconds, required):
            "Select at least \(Int(required)) seconds of this person speaking alone (selected \(Int(seconds.rounded())) s)."
        case .noVoiceprint: "There is no voice data for this speaker. Identify speakers again, then try once more."
        case .inconsistentSelection: "The selected lines don't sound like a single voice. Deselect lines with other people or overlapping speech."
        case .profileNotFound: "That person is no longer in your library."
        case .clusterNotFound: "That speaker no longer exists."
        case .alreadyAssigned: "That person is already assigned to another speaker in this recording."
        }
    }
}

/// How a cluster is shown: a known person's name, with or without a verify marker.
public struct IdentifiedSpeaker: Sendable, Equatable {
    public var profileID: UUID
    public var name: String
    public var needsVerification: Bool
    public var isUserConfirmed: Bool
}

/// Library overview for one person.
public struct ProfileSummary: Sendable, Equatable, Identifiable {
    public var profile: SpeakerProfile
    public var samples: [VoiceSample]
    /// Samples usable with the current engine. Zero means re-enrollment is needed.
    public var compatibleSampleCount: Int
    public var recordingCount: Int
    public var id: UUID { profile.id }
    public var enrolledSeconds: Double { samples.reduce(0) { $0 + $1.speechSeconds } }
}

/// Matching mode shown in the UI. No percentages are shown while provisional.
public struct CalibrationStatus: Sendable, Equatable {
    public var isCalibrated: Bool
    public var confirmedMatches: Int
    public var rejectedMatches: Int
    public var requiredPerClass: Int
}

/// Speaker identity: matching recordings against the enrolled library,
/// explicit enrollment, user decisions, and library management (SPEC FR-5/6).
///
/// Privacy rules enforced here:
/// - Profiles and samples are created only by `enroll`, which requires the
///   caller to pass explicit consent and user-approved lines.
/// - Automatic matches never add samples or change profiles.
/// - User decisions always win over automatic matching.
/// - Deleting a person removes their samples and feedback, and every
///   recording that showed them reverts to a numbered speaker.
public actor IdentityService {
    private static let logger = Logger(subsystem: "com.mietech.MieRecord", category: "Identity")

    /// Minimum approved speech for an enrollment sample.
    public static let minimumEnrollmentSeconds: Double = 5
    /// A window counts toward a sample when it overlaps approved lines this much.
    static let minimumWindowOverlap: Double = 1

    private let recordings: any RecordingRepository
    private let identity: any SpeakerIdentityRepository
    private let policy: IdentityMatchingPolicy
    /// Engine whose embeddings current profiles must match to be usable.
    private let currentEngine: EngineDescriptor?

    public init(
        recordings: any RecordingRepository,
        identity: any SpeakerIdentityRepository,
        currentEngine: EngineDescriptor?,
        policy: IdentityMatchingPolicy = .provisional
    ) {
        self.recordings = recordings
        self.identity = identity
        self.currentEngine = currentEngine
        self.policy = policy
    }

    // MARK: - Matching

    /// Re-decides identities for one recording from its stored voice data.
    @discardableResult
    public func matchSpeakers(recordingID: UUID) async throws -> [SpeakerAttribution] {
        let timeline = try await recordings.speakerTimeline(forRecording: recordingID)
        let clusterIDs = Set(timeline.clusters.map(\.id))
        let existing = try await identity.speakerAttributions(forRecording: recordingID).filter { clusterIDs.contains($0.clusterID) }
        let existingByCluster = Dictionary(existing.map { ($0.clusterID, $0) }, uniquingKeysWith: { first, _ in first })

        guard let voice = try await identity.voiceData(forRecording: recordingID) else {
            try await identity.replaceSpeakerAttributions(existing, forRecording: recordingID)
            return existing
        }
        let voiceprints = ClusterVoiceprint.make(from: voice, timeline: timeline)
        let profileIDs = Set(try await identity.speakerProfiles().map(\.id))
        let samples = try await identity.voiceSamples(forProfile: nil).filter { profileIDs.contains($0.profileID) }
        let decided = IdentityMatcher.decide(
            recordingID: recordingID,
            voiceprints: voiceprints,
            profiles: ProfileVoiceprint.make(from: samples, engine: voice.engine),
            existing: existingByCluster,
            policy: policy
        ).filter { clusterIDs.contains($0.clusterID) }
        try await identity.replaceSpeakerAttributions(decided, forRecording: recordingID)
        try await ReviewState.refresh(recordingID: recordingID, recordings: recordings, identity: identity)
        return decided
    }

    /// Re-matches every recording with voice data, e.g. after the library changed.
    /// Uses stored voiceprints only; no audio is reprocessed.
    public func rematchAll() async throws {
        for recording in try await recordings.allRecordings() where try await identity.voiceData(forRecording: recording.id) != nil {
            try await matchSpeakers(recordingID: recording.id)
        }
    }

    /// Names for identified clusters in a recording, for labeling.
    public func identifiedSpeakers(recordingID: UUID) async throws -> [UUID: IdentifiedSpeaker] {
        let names = Dictionary(try await identity.speakerProfiles().map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        var result: [UUID: IdentifiedSpeaker] = [:]
        for attribution in try await identity.speakerAttributions(forRecording: recordingID) {
            guard let profileID = attribution.status.profileID, let name = names[profileID] else { continue }
            let needsVerification = if case .needsVerification = attribution.status { true } else { false }
            let confirmed = if case .userConfirmed = attribution.status { true } else { false }
            result[attribution.clusterID] = IdentifiedSpeaker(profileID: profileID, name: name, needsVerification: needsVerification, isUserConfirmed: confirmed)
        }
        return result
    }

    /// Speakers in the recording that have voice windows, so they can be
    /// enrolled or matched. Speakers created by hand have none.
    public func clustersWithVoiceprints(recordingID: UUID) async throws -> Set<UUID> {
        Set(try await identity.voiceData(forRecording: recordingID)?.windows.map(\.clusterID) ?? [])
    }

    /// The current decision and evidence for one cluster.
    public func attribution(clusterID: UUID, recordingID: UUID) async throws -> SpeakerAttribution? {
        try await identity.speakerAttributions(forRecording: recordingID).first { $0.clusterID == clusterID }
    }

    // MARK: - User decisions

    /// Accepts an automatic match.
    public func confirm(clusterID: UUID, recordingID: UUID) async throws {
        var attribution = try await requireAttribution(clusterID, recordingID)
        guard let profileID = attribution.status.profileID else { return }
        if !attribution.status.isUserDecision, let score = attribution.evidence?.rawSimilarity, attribution.evidence?.bestProfileID == profileID {
            try await recordFeedback(profileID: profileID, recordingID: recordingID, score: score, same: true, source: .confirmedSuggestion)
        }
        attribution.status = .userConfirmed(profileID: profileID)
        attribution.decidedAt = Date()
        try await save(attribution)
    }

    /// Rejects an automatic match: this speaker is not that person. Matching
    /// runs again and may suggest someone else.
    public func reject(clusterID: UUID, recordingID: UUID) async throws {
        var attribution = try await requireAttribution(clusterID, recordingID)
        guard let profileID = attribution.status.profileID else { return }
        if !attribution.status.isUserDecision, let score = attribution.evidence?.rawSimilarity, attribution.evidence?.bestProfileID == profileID {
            try await recordFeedback(profileID: profileID, recordingID: recordingID, score: score, same: false, source: .rejectedSuggestion)
        }
        attribution.rejectedProfileIDs.insert(profileID)
        attribution.status = .unidentified
        attribution.decidedAt = Date()
        try await save(attribution)
        try await matchSpeakers(recordingID: recordingID)
    }

    /// Marks a speaker as nobody in the library, so no one is suggested.
    public func keepUnidentified(clusterID: UUID, recordingID: UUID) async throws {
        var attribution = try await attributionOrNew(clusterID, recordingID)
        if let profileID = attribution.status.profileID, !attribution.status.isUserDecision,
           let score = attribution.evidence?.rawSimilarity, attribution.evidence?.bestProfileID == profileID {
            try await recordFeedback(profileID: profileID, recordingID: recordingID, score: score, same: false, source: .rejectedSuggestion)
        }
        attribution.status = .userKeptUnidentified
        attribution.decidedAt = Date()
        try await save(attribution)
    }

    /// Says a speaker is a specific known person (a user override, SPEC FR-5).
    /// Throws `alreadyAssigned` when that person is user-confirmed for another
    /// speaker in this recording; the caller should offer to merge them.
    public func assign(clusterID: UUID, recordingID: UUID, profileID: UUID) async throws {
        try await assign(clusterID: clusterID, recordingID: recordingID, profileID: profileID, logFeedback: true)
    }

    /// - Parameter logFeedback: false when the person's voiceprint was just
    ///   made from this cluster; that self-comparison scores near 1.0 and would
    ///   bias calibration.
    private func assign(clusterID: UUID, recordingID: UUID, profileID: UUID, logFeedback: Bool) async throws {
        guard try await identity.speakerProfiles().contains(where: { $0.id == profileID }) else { throw IdentityError.profileNotFound }
        var all = try await identity.speakerAttributions(forRecording: recordingID)
        if let other = all.first(where: { $0.clusterID != clusterID && $0.status == .userConfirmed(profileID: profileID) }) {
            throw IdentityError.alreadyAssigned(otherClusterID: other.clusterID)
        }
        // An automatic claim on the same person elsewhere yields to the user.
        for index in all.indices where all[index].clusterID != clusterID && all[index].status.profileID == profileID {
            all[index].status = .unidentified
        }
        var attribution = all.first { $0.clusterID == clusterID } ?? SpeakerAttribution(clusterID: clusterID, recordingID: recordingID, status: .unidentified)
        if logFeedback, let score = try await similarity(clusterID: clusterID, recordingID: recordingID, profileID: profileID) {
            try await recordFeedback(profileID: profileID, recordingID: recordingID, score: score, same: true, source: .manualAssignment)
        }
        attribution.status = .userConfirmed(profileID: profileID)
        attribution.rejectedProfileIDs.remove(profileID)
        attribution.decidedAt = Date()
        all.removeAll { $0.clusterID == clusterID }
        all.append(attribution)
        try await identity.replaceSpeakerAttributions(all, forRecording: recordingID)
        try await matchSpeakers(recordingID: recordingID)
    }

    /// Returns a speaker to automatic matching.
    public func clearDecision(clusterID: UUID, recordingID: UUID) async throws {
        var attribution = try await attributionOrNew(clusterID, recordingID)
        attribution.status = .unidentified
        try await save(attribution)
        try await matchSpeakers(recordingID: recordingID)
    }

    // MARK: - Enrollment

    public enum EnrollmentTarget: Sendable, Equatable {
        case newProfile(name: String)
        case existingProfile(UUID)
    }

    /// Creates a person, or adds a sample to one, from lines the user approved.
    ///
    /// - Parameters:
    ///   - approvedRanges: time ranges of lines the user selected as this
    ///     person speaking alone.
    ///   - consentGiven: the user confirmed they have permission to store
    ///     this person's voiceprint. Required.
    @discardableResult
    public func enroll(
        recordingID: UUID,
        clusterID: UUID,
        approvedRanges: [TimeRange],
        target: EnrollmentTarget,
        consentGiven: Bool
    ) async throws -> SpeakerProfile {
        guard consentGiven else { throw IdentityError.consentRequired }
        if case let .newProfile(name) = target, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IdentityError.emptyName
        }
        let speech = approvedRanges.reduce(0) { $0 + $1.duration }
        guard speech >= Self.minimumEnrollmentSeconds else {
            throw IdentityError.notEnoughSpeech(seconds: speech, required: Self.minimumEnrollmentSeconds)
        }
        guard let voice = try await identity.voiceData(forRecording: recordingID) else { throw IdentityError.noVoiceprint }
        let windows = voice.windows.filter { window in
            window.clusterID == clusterID && approvedRanges.reduce(0) { total, range in
                total + max(0, min(window.timeRange.end, range.end) - max(window.timeRange.start, range.start))
            } >= Self.minimumWindowOverlap
        }
        guard let vector = VectorMath.centroid(windows.map(\.vector)) else { throw IdentityError.noVoiceprint }
        let consistency = windows.map { VectorMath.cosine($0.vector, vector) }.reduce(0, +) / Double(windows.count)
        guard consistency >= policy.minimumConsistency else { throw IdentityError.inconsistentSelection }

        var profile: SpeakerProfile
        switch target {
        case let .newProfile(name):
            profile = SpeakerProfile(displayName: name.trimmingCharacters(in: .whitespacesAndNewlines))
        case let .existingProfile(id):
            guard let existing = try await identity.speakerProfiles().first(where: { $0.id == id }) else { throw IdentityError.profileNotFound }
            profile = existing
            if let score = try await similarity(clusterID: clusterID, recordingID: recordingID, profileID: id) {
                try await recordFeedback(profileID: id, recordingID: recordingID, score: score, same: true, source: .manualAssignment)
            }
        }
        profile.updatedAt = Date()
        try await identity.saveSpeakerProfile(profile)
        try await identity.saveVoiceSample(VoiceSample(
            profileID: profile.id,
            engine: voice.engine,
            vector: vector,
            speechSeconds: speech,
            sourceRecordingID: recordingID,
            sourceRanges: approvedRanges
        ))
        Self.logger.info("Enrolled voice sample (\(Int(speech)) s) for a profile")

        // Feedback for an existing person was logged above, before this
        // recording's sample could influence the score.
        try await assign(clusterID: clusterID, recordingID: recordingID, profileID: profile.id, logFeedback: false)
        try await rematchAll()
        return profile
    }

    // MARK: - Library

    public func profileSummaries() async throws -> [ProfileSummary] {
        let profiles = try await identity.speakerProfiles()
        let samples = try await identity.voiceSamples(forProfile: nil)
        var recordingCounts: [UUID: Int] = [:]
        for recording in try await recordings.allRecordings() {
            let people = Set(try await identity.speakerAttributions(forRecording: recording.id).compactMap(\.status.profileID))
            for person in people { recordingCounts[person, default: 0] += 1 }
        }
        return profiles.map { profile in
            let own = samples.filter { $0.profileID == profile.id }
            return ProfileSummary(
                profile: profile,
                samples: own,
                compatibleSampleCount: own.filter { $0.engine == currentEngine }.count,
                recordingCount: recordingCounts[profile.id] ?? 0
            )
        }
    }

    public func rename(profileID: UUID, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IdentityError.emptyName }
        guard var profile = try await identity.speakerProfiles().first(where: { $0.id == profileID }) else { throw IdentityError.profileNotFound }
        profile.displayName = trimmed
        profile.updatedAt = Date()
        try await identity.saveSpeakerProfile(profile)
    }

    /// Deletes a person. Recordings that showed them revert to numbered
    /// speakers (including user-confirmed ones), and matching runs again.
    public func deleteProfile(id: UUID) async throws {
        try await identity.deleteSpeakerProfile(id: id)
        for recording in try await recordings.allRecordings() {
            var attributions = try await identity.speakerAttributions(forRecording: recording.id)
            var changed = false
            for index in attributions.indices {
                if attributions[index].status.profileID == id {
                    attributions[index].status = .unidentified
                    changed = true
                }
                if attributions[index].rejectedProfileIDs.remove(id) != nil { changed = true }
                if attributions[index].evidence?.bestProfileID == id {
                    attributions[index].evidence = nil
                    changed = true
                }
            }
            if changed {
                try await identity.replaceSpeakerAttributions(attributions, forRecording: recording.id)
            }
        }
        try await rematchAll()
    }

    public func deleteSample(id: UUID) async throws {
        try await identity.deleteVoiceSample(id: id)
        try await rematchAll()
    }

    public func deleteAllProfiles() async throws {
        for profile in try await identity.speakerProfiles() {
            try await deleteProfile(id: profile.id)
        }
    }

    public func calibrationStatus() async throws -> CalibrationStatus {
        let feedback = try await identity.identityFeedback().filter { $0.engine == currentEngine }
        return CalibrationStatus(
            isCalibrated: policy.isCalibrated,
            confirmedMatches: feedback.filter(\.isSameSpeaker).count,
            rejectedMatches: feedback.filter { !$0.isSameSpeaker }.count,
            requiredPerClass: IdentityCalibration.minimumExamplesPerClass
        )
    }

    // MARK: - Private

    private func requireAttribution(_ clusterID: UUID, _ recordingID: UUID) async throws -> SpeakerAttribution {
        guard let attribution = try await attribution(clusterID: clusterID, recordingID: recordingID) else { throw IdentityError.clusterNotFound }
        return attribution
    }

    private func attributionOrNew(_ clusterID: UUID, _ recordingID: UUID) async throws -> SpeakerAttribution {
        guard try await recordings.speakerTimeline(forRecording: recordingID).clusters.contains(where: { $0.id == clusterID }) else {
            throw IdentityError.clusterNotFound
        }
        return try await attribution(clusterID: clusterID, recordingID: recordingID)
            ?? SpeakerAttribution(clusterID: clusterID, recordingID: recordingID, status: .unidentified)
    }

    private func save(_ attribution: SpeakerAttribution) async throws {
        var all = try await identity.speakerAttributions(forRecording: attribution.recordingID)
        all.removeAll { $0.clusterID == attribution.clusterID }
        all.append(attribution)
        try await identity.replaceSpeakerAttributions(all, forRecording: attribution.recordingID)
        try await ReviewState.refresh(recordingID: attribution.recordingID, recordings: recordings, identity: identity)
    }

    /// Raw similarity of a cluster to a person, when both have comparable voiceprints.
    private func similarity(clusterID: UUID, recordingID: UUID, profileID: UUID) async throws -> Double? {
        guard let voice = try await identity.voiceData(forRecording: recordingID) else { return nil }
        let timeline = try await recordings.speakerTimeline(forRecording: recordingID)
        guard
            let cluster = ClusterVoiceprint.make(from: voice, timeline: timeline).first(where: { $0.clusterID == clusterID }),
            let person = ProfileVoiceprint.make(from: try await identity.voiceSamples(forProfile: profileID), engine: voice.engine).first
        else { return nil }
        return VectorMath.cosine(cluster.vector, person.vector)
    }

    private func recordFeedback(profileID: UUID, recordingID: UUID, score: Double, same: Bool, source: IdentityFeedback.Source) async throws {
        guard let engine = try await identity.voiceData(forRecording: recordingID)?.engine else { return }
        try await identity.saveIdentityFeedback(IdentityFeedback(
            profileID: profileID, recordingID: recordingID, rawSimilarity: score, isSameSpeaker: same, source: source, engine: engine
        ))
    }
}
