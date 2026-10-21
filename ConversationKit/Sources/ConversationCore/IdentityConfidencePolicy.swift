import Foundation

/// The three-tier identity labeling policy from SPEC FR-5.
///
/// The thresholds apply to **calibrated** identity confidence only. Cosine
/// similarity, distances, or logits must never be passed here directly; until a
/// calibration step exists and is validated on held-out recordings, matchers
/// must report `.unidentified` rather than invent a probability.
public struct IdentityConfidencePolicy: Hashable, Sendable {
    /// Below this value a cluster stays `Speaker N`.
    public var verificationThreshold: Double
    /// At or above this value a match is shown without a verification indicator.
    public var recognitionThreshold: Double

    public init(verificationThreshold: Double = 0.60, recognitionThreshold: Double = 0.80) {
        precondition(verificationThreshold <= recognitionThreshold)
        self.verificationThreshold = verificationThreshold
        self.recognitionThreshold = recognitionThreshold
    }

    public static let specDefault = IdentityConfidencePolicy()

    public enum Tier: Hashable, Sendable {
        case unidentified
        case needsVerification
        case recognized
    }

    public func tier(forCalibratedConfidence confidence: Double) -> Tier {
        if confidence >= recognitionThreshold { return .recognized }
        if confidence >= verificationThreshold { return .needsVerification }
        return .unidentified
    }

    /// A candidate match produced by an identity matcher after calibration.
    public struct Candidate: Hashable, Sendable {
        public var profileID: UUID
        public var calibratedConfidence: Double
        public var passedQualityChecks: Bool

        public init(profileID: UUID, calibratedConfidence: Double, passedQualityChecks: Bool) {
            self.profileID = profileID
            self.calibratedConfidence = calibratedConfidence
            self.passedQualityChecks = passedQualityChecks
        }
    }

    /// Decides the attribution for one cluster. `localSpeakerNumber` is only
    /// consumed when the result is unidentified; callers obtain it from
    /// `UnknownSpeakerNumbering`.
    public func status(for candidate: Candidate?, localSpeakerNumber: @autoclosure () -> Int) -> SpeakerAttributionStatus {
        guard let candidate, candidate.passedQualityChecks else {
            return .unidentified(localSpeakerNumber: localSpeakerNumber())
        }
        switch tier(forCalibratedConfidence: candidate.calibratedConfidence) {
        case .recognized:
            return .recognized(profileID: candidate.profileID, confidence: candidate.calibratedConfidence)
        case .needsVerification:
            return .needsVerification(profileID: candidate.profileID, confidence: candidate.calibratedConfidence)
        case .unidentified:
            return .unidentified(localSpeakerNumber: localSpeakerNumber())
        }
    }
}

/// Assigns `Speaker 1…N` to unidentified clusters in order of first appearance.
/// Identified clusters do not consume numbers (SPEC FR-4).
public enum UnknownSpeakerNumbering {
    /// - Parameters:
    ///   - clusters: every cluster in the recording.
    ///   - identifiedClusterIDs: clusters that resolved to a profile.
    /// - Returns: cluster ID → local speaker number for unidentified clusters.
    public static func numbers(
        for clusters: [SpeakerCluster],
        identifiedClusterIDs: Set<UUID>
    ) -> [UUID: Int] {
        let unidentified = clusters
            .filter { !identifiedClusterIDs.contains($0.id) }
            .sorted { lhs, rhs in
                lhs.firstAppearance != rhs.firstAppearance
                    ? lhs.firstAppearance < rhs.firstAppearance
                    : lhs.id.uuidString < rhs.id.uuidString
            }
        var result: [UUID: Int] = [:]
        for (offset, cluster) in unidentified.enumerated() {
            result[cluster.id] = offset + 1
        }
        return result
    }

    public static func label(forLocalSpeakerNumber number: Int) -> String {
        "Speaker \(number)"
    }
}
