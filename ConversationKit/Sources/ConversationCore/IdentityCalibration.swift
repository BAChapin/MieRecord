import Foundation

/// Logistic (Platt) calibration from raw similarity to the probability that a
/// cluster really is the matched person.
///
/// A calibration is usable only when `isValidated`: fitted on enough labeled
/// examples of both outcomes and with a cross-validated expected calibration
/// error under the limit. Until then matching stays in provisional mode.
public struct IdentityCalibration: Hashable, Codable, Sendable {
    public var slope: Double
    public var intercept: Double
    public var engine: EngineDescriptor
    public var positiveCount: Int
    public var negativeCount: Int
    /// Cross-validated expected calibration error, in [0, 1].
    public var expectedCalibrationError: Double
    public var fittedAt: Date

    public static let minimumExamplesPerClass = 30
    public static let maximumExpectedCalibrationError = 0.05

    public init(slope: Double, intercept: Double, engine: EngineDescriptor, positiveCount: Int, negativeCount: Int, expectedCalibrationError: Double, fittedAt: Date = Date()) {
        self.slope = slope
        self.intercept = intercept
        self.engine = engine
        self.positiveCount = positiveCount
        self.negativeCount = negativeCount
        self.expectedCalibrationError = expectedCalibrationError
        self.fittedAt = fittedAt
    }

    public var isValidated: Bool {
        positiveCount >= Self.minimumExamplesPerClass
            && negativeCount >= Self.minimumExamplesPerClass
            && expectedCalibrationError <= Self.maximumExpectedCalibrationError
    }

    public func confidence(forRawSimilarity similarity: Double) -> Double {
        CalibrationFitting.sigmoid(slope * similarity + intercept)
    }
}

/// Fitting and evaluation for `IdentityCalibration`.
public enum CalibrationFitting {
    public struct Example: Hashable, Sendable {
        public var score: Double
        public var isMatch: Bool
        public init(score: Double, isMatch: Bool) {
            self.score = score
            self.isMatch = isMatch
        }
    }

    static func sigmoid(_ x: Double) -> Double { 1 / (1 + exp(-x)) }

    /// Logistic regression on one feature by Newton's method, with Platt's
    /// label smoothing to avoid overconfidence on small, separable data.
    public static func fitPlatt(_ examples: [Example], iterations: Int = 50) -> (slope: Double, intercept: Double)? {
        let positives = Double(examples.filter(\.isMatch).count)
        let negatives = Double(examples.count) - positives
        guard positives > 0, negatives > 0 else { return nil }
        let high = (positives + 1) / (positives + 2)
        let low = 1 / (negatives + 2)
        var a = 0.0, b = log((negatives + 1) / (positives + 1))
        for _ in 0..<iterations {
            var g0 = 0.0, g1 = 0.0, h00 = 1e-12, h01 = 0.0, h11 = 1e-12
            for example in examples {
                let target = example.isMatch ? high : low
                let p = sigmoid(a * example.score + b)
                let d = p - target
                let w = p * (1 - p)
                g0 += d * example.score
                g1 += d
                h00 += w * example.score * example.score
                h01 += w * example.score
                h11 += w
            }
            let determinant = h00 * h11 - h01 * h01
            guard abs(determinant) > 1e-15 else { break }
            let stepA = (h11 * g0 - h01 * g1) / determinant
            let stepB = (h00 * g1 - h01 * g0) / determinant
            a -= stepA
            b -= stepB
            if abs(stepA) + abs(stepB) < 1e-9 { break }
        }
        return a.isFinite && b.isFinite ? (a, b) : nil
    }

    /// Expected calibration error over equal-width probability bins.
    public static func expectedCalibrationError(probabilities: [Double], labels: [Bool], bins: Int = 10) -> Double {
        guard !probabilities.isEmpty, probabilities.count == labels.count else { return 1 }
        var counts = [Int](repeating: 0, count: bins)
        var confidence = [Double](repeating: 0, count: bins)
        var accuracy = [Double](repeating: 0, count: bins)
        for (p, label) in zip(probabilities, labels) {
            let bin = min(bins - 1, max(0, Int(p * Double(bins))))
            counts[bin] += 1
            confidence[bin] += p
            accuracy[bin] += label ? 1 : 0
        }
        let total = Double(probabilities.count)
        return (0..<bins).reduce(0) { sum, bin in
            guard counts[bin] > 0 else { return sum }
            let n = Double(counts[bin])
            return sum + (n / total) * abs(accuracy[bin] / n - confidence[bin] / n)
        }
    }

    /// Fits on all examples and reports k-fold cross-validated ECE, so the
    /// error estimate comes from held-out data.
    public static func calibrate(_ examples: [Example], engine: EngineDescriptor, folds: Int = 5) -> IdentityCalibration? {
        guard let full = fitPlatt(examples) else { return nil }
        let shuffled = examples.enumerated().sorted { ($0.offset * 7919) % 104_729 < ($1.offset * 7919) % 104_729 }.map(\.element)
        var heldOutProbabilities: [Double] = []
        var heldOutLabels: [Bool] = []
        let k = max(2, min(folds, shuffled.count))
        for fold in 0..<k {
            let test = shuffled.enumerated().filter { $0.offset % k == fold }.map(\.element)
            let train = shuffled.enumerated().filter { $0.offset % k != fold }.map(\.element)
            guard let model = fitPlatt(train) else { continue }
            heldOutProbabilities += test.map { sigmoid(model.slope * $0.score + model.intercept) }
            heldOutLabels += test.map(\.isMatch)
        }
        return IdentityCalibration(
            slope: full.slope,
            intercept: full.intercept,
            engine: engine,
            positiveCount: examples.filter(\.isMatch).count,
            negativeCount: examples.filter { !$0.isMatch }.count,
            expectedCalibrationError: expectedCalibrationError(probabilities: heldOutProbabilities, labels: heldOutLabels)
        )
    }
}
