import Foundation

/// Thresholds for automatic identity matching.
///
/// **Provisional mode** (the default until a calibration is validated) uses
/// raw cosine similarity with conservative trial thresholds. These were chosen
/// from a very small set of measurements on 2026-10-21 (one real same-person
/// pair across sessions at 0.80; different clean speakers at most 0.42; pure
/// clusters' consistency 0.94–0.96 versus 0.76–0.82 for clusters mixing
/// voices) and are **not** probabilities. The UI must not present them as
/// percentages.
///
/// **Calibrated mode** maps raw similarity to calibrated confidence and then
/// applies the SPEC's 60% / 80% tiers via `IdentityConfidencePolicy`.
public struct IdentityMatchingPolicy: Hashable, Sendable {
    public var provisionalVerificationSimilarity: Double = 0.70
    public var provisionalRecognitionSimilarity: Double = 0.85
    /// Best candidate must beat the runner-up by at least this much.
    public var minimumMargin: Double = 0.15
    /// Below this the cluster probably mixes voices.
    public var minimumConsistency: Double = 0.88
    public var minimumCleanSpeechSeconds: Double = 4
    public var minimumWindows: Int = 1
    /// Active only when validated; see `IdentityCalibration.isValidated`.
    public var calibration: IdentityCalibration?
    public var confidencePolicy: IdentityConfidencePolicy = .specDefault

    public init(calibration: IdentityCalibration? = nil) {
        self.calibration = calibration
    }

    public static let provisional = IdentityMatchingPolicy()

    public var isCalibrated: Bool { calibration?.isValidated == true }

    /// The tier for a raw similarity, plus calibrated confidence when available.
    public func tier(forRawSimilarity similarity: Double) -> (IdentityConfidencePolicy.Tier, calibrated: Double?) {
        if let calibration, calibration.isValidated {
            let confidence = calibration.confidence(forRawSimilarity: similarity)
            return (confidencePolicy.tier(forCalibratedConfidence: confidence), confidence)
        }
        if similarity >= provisionalRecognitionSimilarity { return (.recognized, nil) }
        if similarity >= provisionalVerificationSimilarity { return (.needsVerification, nil) }
        return (.unidentified, nil)
    }
}

/// Decides identities for a recording's clusters against enrolled profiles.
///
/// Rules (SPEC FR-5):
/// - User decisions (`userConfirmed`, `userKeptUnidentified`) are kept as is.
/// - Quality gates run first; a failing cluster stays unidentified whatever
///   its score.
/// - A rejected person is never suggested again for that cluster.
/// - One person is assigned to at most one cluster per recording: the
///   strongest claim wins, others fall back to their next eligible person or
///   stay unidentified.
/// - The best person must beat the runner-up by `minimumMargin`.
public enum IdentityMatcher {
    public static func decide(
        recordingID: UUID,
        voiceprints: [ClusterVoiceprint],
        profiles: [ProfileVoiceprint],
        existing: [UUID: SpeakerAttribution],
        policy: IdentityMatchingPolicy,
        now: Date = Date()
    ) -> [SpeakerAttribution] {
        // People already chosen by the user in this recording are taken.
        var taken = Set(existing.values.compactMap { $0.status.isUserDecision ? $0.status.profileID : nil })

        struct Candidate {
            let clusterID: UUID
            let profileID: UUID
            let similarity: Double
        }

        var results: [UUID: SpeakerAttribution] = [:]
        var claims: [Candidate] = []
        var evidenceByCluster: [UUID: IdentityEvidence] = [:]

        for print in voiceprints {
            let previous = existing[print.clusterID]
            if let previous, previous.status.isUserDecision {
                results[print.clusterID] = previous
                continue
            }
            let rejected = previous?.rejectedProfileIDs ?? []
            var evidence = IdentityEvidence(scoringEngine: print.engine)

            if print.cleanSpeechSeconds < policy.minimumCleanSpeechSeconds || print.windowCount < policy.minimumWindows {
                evidence.issues.insert(.tooLittleSpeech)
            }
            if print.consistency < policy.minimumConsistency {
                evidence.issues.insert(.inconsistentVoice)
            }
            if profiles.isEmpty {
                evidence.issues.insert(.noCompatibleVoiceprint)
            }

            let scored = profiles
                .filter { !rejected.contains($0.profileID) }
                .map { (profileID: $0.profileID, similarity: VectorMath.cosine(print.vector, $0.vector)) }
                .sorted { $0.similarity > $1.similarity }
            if let best = scored.first {
                evidence.bestProfileID = best.profileID
                evidence.rawSimilarity = best.similarity
                let runnerUp = scored.dropFirst().first?.similarity
                evidence.margin = runnerUp.map { best.similarity - $0 }
                if let margin = evidence.margin, margin < policy.minimumMargin, policy.tier(forRawSimilarity: best.similarity).0 != .unidentified {
                    evidence.issues.insert(.ambiguousBetweenPeople)
                }
                evidence.calibratedConfidence = policy.tier(forRawSimilarity: best.similarity).calibrated
            }
            evidenceByCluster[print.clusterID] = evidence

            if evidence.issues.isEmpty {
                for entry in scored where policy.tier(forRawSimilarity: entry.similarity).0 != .unidentified {
                    claims.append(Candidate(clusterID: print.clusterID, profileID: entry.profileID, similarity: entry.similarity))
                }
            }
            results[print.clusterID] = SpeakerAttribution(
                clusterID: print.clusterID,
                recordingID: recordingID,
                status: .unidentified,
                evidence: evidence,
                rejectedProfileIDs: rejected,
                decidedAt: now
            )
        }

        // Greedy one-to-one assignment, strongest claim first.
        var assignedClusters = Set<UUID>()
        for claim in claims.sorted(by: { $0.similarity > $1.similarity }) {
            guard !assignedClusters.contains(claim.clusterID), !taken.contains(claim.profileID) else { continue }
            let (tier, calibrated) = policy.tier(forRawSimilarity: claim.similarity)
            guard var attribution = results[claim.clusterID] else { continue }
            attribution.status = tier == .recognized
                ? .recognized(profileID: claim.profileID)
                : .needsVerification(profileID: claim.profileID)
            var evidence = evidenceByCluster[claim.clusterID] ?? IdentityEvidence()
            if evidence.bestProfileID != claim.profileID {
                // Fell back to a lower candidate: never claim the top tier.
                attribution.status = .needsVerification(profileID: claim.profileID)
                evidence.bestProfileID = claim.profileID
                evidence.rawSimilarity = claim.similarity
                evidence.calibratedConfidence = calibrated
            }
            attribution.evidence = evidence
            results[claim.clusterID] = attribution
            assignedClusters.insert(claim.clusterID)
            taken.insert(claim.profileID)
        }

        // Keep attributions for clusters without a voiceprint (for example
        // user-created speakers) as they were.
        for (clusterID, attribution) in existing where results[clusterID] == nil {
            results[clusterID] = attribution
        }
        return results.values.sorted { $0.clusterID.uuidString < $1.clusterID.uuidString }
    }
}
