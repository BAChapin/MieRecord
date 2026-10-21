import Foundation

/// The independently retryable stages of post-recording processing (SPEC FR-3).
/// Milestone 1 defines the stages so persistence and UI can represent them, but
/// no stage beyond live transcription is executed yet.
public enum ProcessingStage: String, Codable, CaseIterable, Sendable {
    case transcriptionFinalization
    case diarization
    case embeddingExtraction
    case identityMatching
    case alignment
    case persistence
}

public struct ProcessingFailure: Hashable, Codable, Sendable {
    public var stage: ProcessingStage?
    public var message: String
    public var occurredAt: Date

    public init(stage: ProcessingStage?, message: String, occurredAt: Date = Date()) {
        self.stage = stage
        self.message = message
        self.occurredAt = occurredAt
    }
}

/// User-visible processing status for a recording (queued, processing, needs
/// review, ready, failed) as required by SPEC FR-3.
public enum ProcessingState: Hashable, Codable, Sendable {
    case notStarted
    case queued
    case processing(ProcessingStage)
    case needsReview
    case ready
    case failed(ProcessingFailure)

    public var isTerminal: Bool {
        switch self {
        case .ready, .failed, .needsReview: true
        case .notStarted, .queued, .processing: false
        }
    }
}
